// Sandboxed repository access for the agents.
// Everything the agents may read or change goes through here.

const fs = require("fs");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");

// Never readable, never writable - no matter what an agent asks for.
const BLOCKED = [".git", "agents/state", "agents/logs", "node_modules"];

function resolveInsideRepo(relPath) {
    const absolute = path.resolve(ROOT, relPath);
    const relative = path.relative(ROOT, absolute);
    if (relative.startsWith("..") || path.isAbsolute(relative)) {
        throw new Error("Pfad liegt ausserhalb des Repos: " + relPath);
    }
    for (const blocked of BLOCKED) {
        if (relative === blocked || relative.startsWith(blocked + path.sep)) {
            throw new Error("Pfad ist gesperrt: " + relPath);
        }
    }
    return { absolute, relative };
}

function listFiles() {
    const out = [];
    const walk = (dir) => {
        for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
            const absolute = path.join(dir, entry.name);
            const relative = path.relative(ROOT, absolute);
            if (BLOCKED.some((b) => relative === b || relative.startsWith(b + path.sep))) continue;
            if (entry.isDirectory()) walk(absolute);
            else out.push({ path: relative, bytes: fs.statSync(absolute).size });
        }
    };
    walk(ROOT);
    return out.sort((a, b) => a.path.localeCompare(b.path));
}

// Line-addressed read so an agent can page through a 40 KB userscript
// instead of pulling the whole thing into context every time.
function readFile(relPath, offset = 1, limit = 200) {
    const { absolute, relative } = resolveInsideRepo(relPath);
    if (!fs.existsSync(absolute)) throw new Error("Datei existiert nicht: " + relative);

    const lines = fs.readFileSync(absolute, "utf8").split("\n");
    const start = Math.max(1, Number(offset) || 1);
    const count = Math.min(Math.max(1, Number(limit) || 200), 600);
    const slice = lines.slice(start - 1, start - 1 + count);

    return {
        path: relative,
        totalLines: lines.length,
        firstLine: start,
        lastLine: Math.min(lines.length, start - 1 + count),
        content: slice.map((line, i) => (start + i) + "\t" + line).join("\n")
    };
}

function search(pattern, relPath) {
    let regex;
    try {
        regex = new RegExp(pattern, "g");
    } catch (err) {
        throw new Error("Ungueltiges Suchmuster: " + err.message);
    }

    const targets = relPath ? [{ path: resolveInsideRepo(relPath).relative }] : listFiles();
    const hits = [];

    for (const target of targets) {
        const absolute = path.join(ROOT, target.path);
        if (!fs.statSync(absolute).isFile()) continue;

        let text;
        try {
            text = fs.readFileSync(absolute, "utf8");
        } catch (err) {
            continue; // binary or unreadable, skip
        }

        text.split("\n").forEach((line, index) => {
            regex.lastIndex = 0;
            if (regex.test(line)) {
                hits.push({ path: target.path, line: index + 1, text: line.trim().slice(0, 200) });
            }
        });

        if (hits.length > 200) break;
    }

    return hits.slice(0, 200);
}

// Staged edits: search/replace pairs that must match exactly once.
// Nothing touches the working tree until applyEdits() runs.
function validateEdit(edit, allowedPaths) {
    const { absolute, relative } = resolveInsideRepo(edit.path);

    if (!allowedPaths.includes(relative)) {
        throw new Error(
            "Datei steht nicht in editablePaths (agents/config.json): " + relative +
            "\nErlaubt: " + allowedPaths.join(", ")
        );
    }
    if (!fs.existsSync(absolute)) throw new Error("Datei existiert nicht: " + relative);
    if (typeof edit.search !== "string" || edit.search.length === 0) {
        throw new Error("'search' fehlt oder ist leer.");
    }
    if (typeof edit.replace !== "string") {
        throw new Error("'replace' fehlt.");
    }
    if (edit.search === edit.replace) {
        throw new Error("'search' und 'replace' sind identisch - das waere keine Aenderung.");
    }

    const content = fs.readFileSync(absolute, "utf8");
    const occurrences = content.split(edit.search).length - 1;
    if (occurrences === 0) {
        throw new Error(
            "'search' kommt in " + relative + " nicht vor. " +
            "Lies die Stelle mit read_file erneut und kopiere den Text exakt, inklusive Einrueckung."
        );
    }
    if (occurrences > 1) {
        throw new Error(
            "'search' kommt " + occurrences + "x in " + relative + " vor und ist damit nicht eindeutig. " +
            "Nimm mehr Kontextzeilen dazu."
        );
    }

    return { path: relative, absolute };
}

function applyEdits(edits) {
    // Group by file so multiple edits to one file are written once.
    const byFile = new Map();
    for (const edit of edits) {
        const { absolute, relative } = resolveInsideRepo(edit.path);
        if (!byFile.has(relative)) byFile.set(relative, { absolute, content: fs.readFileSync(absolute, "utf8") });
        const file = byFile.get(relative);

        const occurrences = file.content.split(edit.search).length - 1;
        if (occurrences !== 1) {
            throw new Error(
                "Edit passt beim Anwenden nicht mehr eindeutig (" + occurrences + " Treffer) in " + relative +
                ". Lauf abgebrochen, keine Datei veraendert."
            );
        }
        file.content = file.content.replace(edit.search, edit.replace);
    }

    for (const [relative, file] of byFile) {
        fs.writeFileSync(file.absolute, file.content, "utf8");
    }
    return [...byFile.keys()];
}

module.exports = { ROOT, listFiles, readFile, search, validateEdit, applyEdits, resolveInsideRepo };
