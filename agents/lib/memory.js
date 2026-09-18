// Shared memory across runs. This is what keeps the agents from proposing
// the same three things forever: every run reads it and writes it back.

const fs = require("fs");
const path = require("path");

const STATE_DIR = path.resolve(__dirname, "..", "state");
const BACKLOG_JSON = path.join(STATE_DIR, "backlog.json");
const BACKLOG_MD = path.resolve(__dirname, "..", "BACKLOG.md");
const JOURNAL_MD = path.resolve(__dirname, "..", "JOURNAL.md");

function load() {
    if (!fs.existsSync(BACKLOG_JSON)) return { nextId: 1, items: [] };
    try {
        const state = JSON.parse(fs.readFileSync(BACKLOG_JSON, "utf8"));
        return { nextId: state.nextId || 1, items: state.items || [] };
    } catch (err) {
        throw new Error("agents/state/backlog.json ist kaputt: " + err.message);
    }
}

function save(state) {
    fs.mkdirSync(STATE_DIR, { recursive: true });
    fs.writeFileSync(BACKLOG_JSON, JSON.stringify(state, null, 2) + "\n", "utf8");
    fs.writeFileSync(BACKLOG_MD, renderBacklog(state), "utf8");
}

function renderBacklog(state) {
    const section = (title, items, withNote) => {
        if (items.length === 0) return "## " + title + "\n\n_(leer)_\n";
        const lines = items.map((item) => {
            let line = "- **#" + item.id + "** " + item.title;
            if (withNote && item.note) line += "\n  - " + item.note.replace(/\n/g, " ");
            return line;
        });
        return "## " + title + "\n\n" + lines.join("\n") + "\n";
    };

    const open = state.items.filter((i) => i.status === "open");
    const done = state.items.filter((i) => i.status === "done");
    const rejected = state.items.filter((i) => i.status === "rejected");

    return [
        "# Backlog",
        "",
        "Diese Datei wird von `agents/run.js` geschrieben. Du kannst sie von Hand",
        "bearbeiten - die Agenten lesen sie beim naechsten Lauf. Massgeblich ist",
        "`agents/state/backlog.json`, diese Markdown-Datei ist die lesbare Ansicht.",
        "",
        section("Offen", open, true),
        section("Erledigt", done, true),
        section("Verworfen", rejected, true)
    ].join("\n");
}

function addItem(state, { title, rationale, acceptance }) {
    const item = {
        id: state.nextId++,
        title,
        rationale: rationale || "",
        acceptance: acceptance || "",
        status: "open",
        note: "",
        createdAt: new Date().toISOString()
    };
    state.items.push(item);
    return item;
}

function closeItem(state, id, status, note) {
    const item = state.items.find((i) => i.id === id);
    if (!item) return null;
    item.status = status;
    item.note = note || "";
    item.updatedAt = new Date().toISOString();
    return item;
}

// A compact view of history, so the scout knows what has already been
// tried without receiving the whole backlog verbatim.
function historyDigest(state) {
    const lines = [];
    for (const item of state.items) {
        if (item.status === "open") continue;
        const label = item.status === "done" ? "ERLEDIGT" : "VERWORFEN";
        lines.push("- [" + label + "] #" + item.id + " " + item.title + (item.note ? " - " + item.note : ""));
    }
    return lines.length > 0 ? lines.join("\n") : "(noch nichts erledigt oder verworfen)";
}

function appendJournal(entry) {
    const header = "\n## " + new Date().toISOString() + "\n\n";
    const body = entry.trimEnd() + "\n";
    if (!fs.existsSync(JOURNAL_MD)) {
        fs.writeFileSync(JOURNAL_MD, "# Journal\n\nWas die Agenten pro Lauf getan haben, neueste Eintraege unten.\n", "utf8");
    }
    fs.appendFileSync(JOURNAL_MD, header + body, "utf8");
}

module.exports = { load, save, addItem, closeItem, historyDigest, appendJournal, BACKLOG_MD, JOURNAL_MD };
