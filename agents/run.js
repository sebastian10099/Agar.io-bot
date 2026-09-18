#!/usr/bin/env node
// Orchestrator: fuehrt einen Lauf der Agentenkette aus.
//
//   Scout -> Critic -> (Implementer <-> Reviewer) -> Curator
//
// Jeder Agent bekommt das Ergebnis des vorigen als Nachricht. Ein Lauf endet
// immer: entweder der Critic stoppt, der Reviewer lehnt endgueltig ab, das
// Budget ist aufgebraucht, oder ein Patch ist fertig. Es gibt keine Schleife,
// die von selbst weiterlaeuft - Wiederholung ist Sache von cron/launchd.

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const openrouter = require("./lib/openrouter");
const repo = require("./lib/repo");
const memory = require("./lib/memory");
const roles = require("./lib/roles");
const { runAgent, makeBudget, BudgetExceeded, formatUsd } = require("./lib/agent");

const AGENTS_DIR = __dirname;
const CONFIG_PATH = path.join(AGENTS_DIR, "config.json");
const STOP_FILE = path.join(AGENTS_DIR, "STOP");

// --- CLI ----------------------------------------------------------------

function parseArgs(argv) {
    const options = {
        apply: false,
        commit: false,
        budgetUsd: null,
        maxReviewRounds: null,
        model: null,
        listModels: false,
        skipModelCheck: false
    };

    for (const arg of argv) {
        if (arg === "--apply") options.apply = true;
        else if (arg === "--commit") { options.commit = true; options.apply = true; }
        else if (arg === "--list-models") options.listModels = true;
        else if (arg === "--no-model-check") options.skipModelCheck = true;
        else if (arg.startsWith("--budget=")) options.budgetUsd = Number(arg.slice(9));
        else if (arg.startsWith("--max-reviews=")) options.maxReviewRounds = Number(arg.slice(14));
        else if (arg.startsWith("--model=")) options.model = arg.slice(8);
        else if (arg === "--help" || arg === "-h") options.help = true;
        else throw new Error("Unbekannte Option: " + arg);
    }
    return options;
}

const HELP = `
agents/run.js - ein Lauf der Agentenkette ueber OpenRouter

  node agents/run.js                 Probelauf, schreibt nur nach agents/out/
  node agents/run.js --apply         Wendet den Patch auf die Dateien an
  node agents/run.js --commit        Wendet an und committet (pusht NICHT)
  node agents/run.js --list-models   Zeigt die verfuegbaren OpenRouter-Modelle

Optionen:
  --budget=2.50        Kostendeckel in USD fuer diesen Lauf (Standard aus config.json)
  --max-reviews=3      Wie oft der Reviewer zurueckgeben darf (Standard aus config.json)
  --model=<slug>       Ueberschreibt alle Rollen mit einem Modell
  --no-model-check     Ueberspringt die Pruefung der Modellnamen beim Start

Voraussetzung:
  export OPENROUTER_API_KEY=sk-or-...
  Modelle in agents/config.json eintragen oder OPENROUTER_MODEL setzen.

Abbruch: eine Datei agents/STOP anlegen - dann beendet sich jeder Lauf sofort.
`.trim();

// --- Logging ------------------------------------------------------------

const logLines = [];

function log(line) {
    console.log(line);
    logLines.push(line);
}

function logSection(title) {
    log("");
    log("=== " + title + " ===");
}

// Der Nachrichtenverkehr zwischen den Agenten, damit nachlesbar ist,
// wer wem was geschrieben hat.
const mail = [];

function handoff(from, to, payload) {
    mail.push({ from, to, payload });
    log("  -> " + from + " schreibt an " + to);
}

function writeLog(status) {
    const stamp = new Date().toISOString().replace(/[:.]/g, "-");
    const file = path.join(AGENTS_DIR, "logs", stamp + "-" + status + ".md");

    const body = [
        "# Lauf " + stamp + " (" + status + ")",
        "",
        "## Konsole",
        "",
        "```",
        logLines.join("\n"),
        "```",
        "",
        "## Nachrichten zwischen den Agenten",
        ""
    ];

    for (const entry of mail) {
        body.push("### " + entry.from + " -> " + entry.to, "", "```json", JSON.stringify(entry.payload, null, 2), "```", "");
    }

    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, body.join("\n"), "utf8");
    return file;
}

// --- Vorbereitung -------------------------------------------------------

function loadConfig(options) {
    const config = JSON.parse(fs.readFileSync(CONFIG_PATH, "utf8"));
    const fallback = options.model || process.env.OPENROUTER_MODEL || null;

    for (const role of Object.keys(config.models)) {
        config.models[role] = options.model || config.models[role] || fallback;
    }

    const missing = Object.entries(config.models).filter(([, value]) => !value).map(([role]) => role);
    if (missing.length > 0) {
        throw new Error(
            "Kein Modell fuer: " + missing.join(", ") + ".\n" +
            "Trage die Slugs in agents/config.json ein, oder setze ein Modell fuer alle Rollen:\n" +
            "  export OPENROUTER_MODEL=<slug>\n" +
            "Verfuegbare Slugs: node agents/run.js --list-models  (oder https://openrouter.ai/models)"
        );
    }

    if (options.budgetUsd !== null) config.limits.budgetUsd = options.budgetUsd;
    if (options.maxReviewRounds !== null) config.limits.maxReviewRounds = options.maxReviewRounds;

    return config;
}

async function checkModels(config) {
    const available = new Set(await openrouter.listModels());
    const unknown = [...new Set(Object.values(config.models))].filter((slug) => !available.has(slug));

    if (unknown.length > 0) {
        const suggestions = unknown.map((slug) => {
            const stem = slug.split("/").pop().split("-")[0].toLowerCase();
            const close = [...available].filter((id) => id.toLowerCase().includes(stem)).slice(0, 5);
            return "  " + slug + (close.length > 0 ? "\n    vielleicht: " + close.join(", ") : "");
        });
        throw new Error(
            "Diese Modelle kennt OpenRouter nicht:\n" + suggestions.join("\n") +
            "\nVollstaendige Liste: node agents/run.js --list-models"
        );
    }
}

function gitCommit(files, message) {
    execFileSync("git", ["add", "--", ...files], { cwd: repo.ROOT, stdio: "inherit" });
    execFileSync("git", ["commit", "-m", message], { cwd: repo.ROOT, stdio: "inherit" });
    return execFileSync("git", ["rev-parse", "--short", "HEAD"], { cwd: repo.ROOT, encoding: "utf8" }).trim();
}

function renderEdits(edits) {
    return edits.map((edit, index) =>
        "--- Aenderung " + (index + 1) + " in " + edit.path + " ---" +
        (edit.note ? "\n// " + edit.note : "") +
        "\nVORHER:\n" + edit.search +
        "\nNACHHER:\n" + edit.replace
    ).join("\n\n");
}

// --- Lauf ---------------------------------------------------------------

async function main() {
    const options = parseArgs(process.argv.slice(2));

    if (options.help) { console.log(HELP); return 0; }

    if (options.listModels) {
        const models = await openrouter.listModels();
        console.log(models.sort().join("\n"));
        console.log("\n" + models.length + " Modelle verfuegbar.");
        return 0;
    }

    if (fs.existsSync(STOP_FILE)) {
        console.log("agents/STOP existiert - Lauf wird nicht gestartet. Datei loeschen, um wieder zu starten.");
        return 0;
    }

    const config = loadConfig(options);
    const budget = makeBudget(config.limits.budgetUsd);

    log("Agar.io-bot Agenten - " + new Date().toISOString());
    log("Modus: " + (options.commit ? "anwenden und committen" : options.apply ? "anwenden" : "Probelauf (nichts wird geschrieben)"));
    log("Budget: $" + formatUsd(config.limits.budgetUsd));

    if (!options.skipModelCheck) await checkModels(config);

    const state = memory.load();
    const open = state.items.filter((item) => item.status === "open");
    log("Backlog: " + open.length + " offen, " + (state.items.length - open.length) + " abgeschlossen");

    // 1. Scout
    logSection("Scout");
    const scoutResult = await runAgent({
        name: roles.scout.name,
        model: config.models.scout,
        system: roles.scout.system,
        task: [
            "Verlauf bisheriger Vorhaben (nicht wiederholen):",
            memory.historyDigest(state),
            "",
            "Offene Punkte im Backlog:",
            open.length > 0
                ? open.map((item) => "- #" + item.id + " " + item.title + " - " + item.rationale).join("\n")
                : "(keine)",
            "",
            "Sieh dir den Code an und schlage Kandidaten vor. Offene Backlog-Punkte",
            "darfst du uebernehmen, wenn sie noch sinnvoll sind."
        ].join("\n"),
        toolset: roles.scout.tools,
        maxSteps: config.limits.maxStepsPerAgent,
        budget,
        log
    });

    const candidates = scoutResult.result.candidates || [];
    log("Scout: " + candidates.length + " Kandidat(en)");
    handoff("Scout", "Critic", scoutResult.result);

    if (candidates.length === 0 && open.length === 0) {
        log("Nichts vorgeschlagen und nichts offen - Lauf beendet.");
        memory.appendJournal("Scout hat keine Kandidaten gefunden, Backlog ist leer. Kein Patch. Kosten: $" + budget.spentUsd.toFixed(4));
        log("Log: " + writeLog("leer"));
        return 0;
    }

    // 2. Critic
    logSection("Critic");
    const criticResult = await runAgent({
        name: roles.critic.name,
        model: config.models.critic,
        system: roles.critic.system,
        task: [
            "Nachricht vom Scout:",
            JSON.stringify(scoutResult.result, null, 2),
            "",
            "Offene Backlog-Punkte:",
            open.length > 0 ? open.map((item) => "- #" + item.id + " " + item.title).join("\n") : "(keine)",
            "",
            "Verlauf (schon erledigt oder verworfen):",
            memory.historyDigest(state),
            "",
            "Entscheide: einen Punkt auswaehlen oder den Lauf stoppen."
        ].join("\n"),
        toolset: roles.critic.tools,
        maxSteps: config.limits.maxStepsPerAgent,
        budget,
        log
    });

    handoff("Critic", criticResult.result.decision === "stop" ? "(Lauf-Ende)" : "Implementer", criticResult.result);

    if (criticResult.result.decision === "stop") {
        log("Critic stoppt: " + criticResult.result.reason);
        memory.appendJournal("Critic hat den Lauf gestoppt: " + criticResult.result.reason + "\n\nKosten: $" + budget.spentUsd.toFixed(4));
        memory.save(state);
        log("Log: " + writeLog("gestoppt"));
        return 0;
    }

    const assignment = criticResult.result;
    log("Critic waehlt: " + assignment.title);

    // 3. Implementer <-> Reviewer
    let edits = [];
    let implementResult = null;
    let reviewResult = null;
    let objections = [];

    const maxRounds = config.limits.maxReviewRounds + 1;

    for (let round = 1; round <= maxRounds; round++) {
        logSection("Implementer (Runde " + round + " von " + maxRounds + ")");

        const stage = { edits: [], allowedPaths: config.editablePaths };
        const impl = roles.implementer(stage);

        implementResult = await runAgent({
            name: impl.name,
            model: config.models.implementer,
            system: impl.system,
            task: [
                "Auftrag vom Critic:",
                "Titel: " + assignment.title,
                "Plan: " + (assignment.plan || assignment.reason),
                "Abnahme: " + (assignment.acceptance || "-"),
                "",
                objections.length > 0
                    ? "Der Reviewer hat deinen vorigen Versuch abgelehnt. Einwaende:\n" +
                      objections.map((o) => "- " + o).join("\n") +
                      "\n\nFange neu an und behebe diese Punkte."
                    : "Setze den Auftrag um.",
                "",
                "Aenderbare Dateien: " + config.editablePaths.join(", ")
            ].join("\n"),
            toolset: impl.tools,
            maxSteps: config.limits.maxStepsPerAgent,
            budget,
            log
        });

        edits = stage.edits;

        if (edits.length === 0) {
            log("Implementer hat keine Aenderung vorgemerkt - Lauf beendet.");
            memory.appendJournal(
                "Implementer hat fuer '" + assignment.title + "' keine Aenderung erzeugt.\n\nKosten: $" + budget.spentUsd.toFixed(4)
            );
            log("Log: " + writeLog("ohne-patch"));
            return 0;
        }

        log("Implementer: " + edits.length + " Aenderung(en)");
        handoff("Implementer", "Reviewer", { summary: implementResult.result.summary, edits });

        logSection("Reviewer (Runde " + round + ")");
        reviewResult = await runAgent({
            name: roles.reviewer.name,
            model: config.models.reviewer,
            system: roles.reviewer.system,
            task: [
                "Auftrag des Critics:",
                "Titel: " + assignment.title,
                "Plan: " + (assignment.plan || assignment.reason),
                "Abnahme: " + (assignment.acceptance || "-"),
                "",
                "Nachricht vom Implementer:",
                implementResult.result.summary,
                "",
                "Der Patch (noch nicht angewendet):",
                renderEdits(edits),
                "",
                "Hinweis: Die Dateien auf der Platte sind noch der Stand VOR dem Patch."
            ].join("\n"),
            toolset: roles.reviewer.tools,
            maxSteps: config.limits.maxStepsPerAgent,
            budget,
            log
        });

        handoff("Reviewer", reviewResult.result.approved ? "Curator" : "Implementer", reviewResult.result);

        if (reviewResult.result.approved) {
            log("Reviewer: angenommen - " + reviewResult.result.comment);
            break;
        }

        objections = reviewResult.result.objections || [];
        log("Reviewer: abgelehnt - " + reviewResult.result.comment);

        if (round === maxRounds) {
            log("Maximale Zahl an Review-Runden erreicht - Lauf endet ohne Patch.");
            memory.closeItem(state, memory.addItem(state, {
                title: assignment.title,
                rationale: assignment.plan || assignment.reason,
                acceptance: assignment.acceptance
            }).id, "rejected", "Review nach " + maxRounds + " Runden nicht bestanden: " + (objections[0] || reviewResult.result.comment));
            memory.save(state);
            memory.appendJournal(
                "'" + assignment.title + "' hat das Review nicht bestanden und wurde verworfen.\n" +
                "Letzte Einwaende: " + objections.join(" | ") + "\n\nKosten: $" + budget.spentUsd.toFixed(4)
            );
            log("Log: " + writeLog("abgelehnt"));
            return 0;
        }
    }

    // 4. Patch anwenden
    logSection("Ergebnis");
    let changedFiles = [];

    if (options.apply) {
        changedFiles = repo.applyEdits(edits);
        log("Geschrieben: " + changedFiles.join(", "));
    } else {
        const outDir = path.join(AGENTS_DIR, "out");
        fs.mkdirSync(outDir, { recursive: true });
        const outFile = path.join(outDir, "patch-" + Date.now() + ".md");
        fs.writeFileSync(outFile, "# " + assignment.title + "\n\n" + implementResult.result.summary + "\n\n```\n" + renderEdits(edits) + "\n```\n", "utf8");
        log("Probelauf - nichts geaendert. Vorschlag liegt in " + path.relative(repo.ROOT, outFile));
    }

    // 5. Curator
    logSection("Curator");
    const curatorResult = await runAgent({
        name: roles.curator.name,
        model: config.models.curator,
        system: roles.curator.system,
        task: [
            "Dieser Lauf:",
            "Vorhaben: " + assignment.title,
            "Umgesetzt: " + implementResult.result.summary,
            "Review: " + reviewResult.result.comment,
            "Angewendet: " + (options.apply ? "ja" : "nein (Probelauf)"),
            "",
            "Weitere Kandidaten des Scouts, die nicht drankamen:",
            JSON.stringify(candidates.filter((c) => c.title !== assignment.title), null, 2),
            "",
            "Schreibe Journal und Backlog fort."
        ].join("\n"),
        toolset: roles.curator.tools,
        maxSteps: 4,
        budget,
        log
    });

    handoff("Curator", "(Gedaechtnis)", curatorResult.result);

    const doneItem = memory.addItem(state, {
        title: assignment.title,
        rationale: assignment.plan || assignment.reason,
        acceptance: assignment.acceptance
    });
    memory.closeItem(state, doneItem.id, options.apply ? "done" : "open",
        options.apply ? implementResult.result.summary : "Probelauf, Patch noch nicht angewendet.");

    for (const addition of curatorResult.result.backlogAdditions || []) {
        memory.addItem(state, addition);
    }
    memory.save(state);

    let commitLine = "";
    if (options.commit && changedFiles.length > 0) {
        const message = (implementResult.result.commitMessage || assignment.title) +
            "\n\n" + implementResult.result.summary +
            "\n\nUmgesetzt von agents/run.js (Scout -> Critic -> Implementer -> Reviewer).";
        const sha = gitCommit(changedFiles, message);
        commitLine = "\nCommit: " + sha;
        log("Commit: " + sha + " (nicht gepusht)");
    }

    memory.appendJournal(
        curatorResult.result.journal +
        "\n\nVorhaben: " + assignment.title +
        "\nKosten: $" + budget.spentUsd.toFixed(4) + commitLine
    );

    log("");
    log("Fertig. Kosten: $" + budget.spentUsd.toFixed(4));
    log("Log: " + writeLog("fertig"));
    return 0;
}

main()
    .then((code) => process.exit(code))
    .catch((err) => {
        if (err instanceof BudgetExceeded) {
            console.error("\n" + err.message);
            try { memory.appendJournal("Lauf wegen Budgetgrenze abgebrochen: " + err.message); } catch (e) {}
            writeLog("budget");
            process.exit(2);
        }
        console.error("\nFehler: " + err.message);
        try { writeLog("fehler"); } catch (e) {}
        process.exit(1);
    });
