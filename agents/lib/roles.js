// Role definitions: what each agent may do, and what it is told.

const repo = require("./repo");

const PROJECT_BRIEF = `
Projekt: Agar.io-bot (AposBot) - ein Userscript-Bot fuer das Browserspiel agar.io.

Aufbau:
- launcher.user.js  Der Launcher. Haelt die Agenten-Registry 'window.botList'
                    (Eintraege der Form [name, funktion]) und ruft pro Frame
                    genau einen Eintrag auf: window.botList[botIndex][1](toggleFollow).
                    Der Rueckgabewert ist ein Zielpunkt [x, y].
- bot.user.js       Die stabile Bot-Strategie, registriert sich als "AposBot".
- beta.user.js      Die Beta-Strategie, registriert sich als "AposBotBeta".

Ein "Bot" ist also nichts weiter als eine Funktion, die [x, y] zurueckgibt.

Wichtige Rahmenbedingungen:
- Es gibt keine Tests, keine CI, keinen Build. Der Code laeuft ausschliesslich
  live im Browser gegen echte Gegner. Du kannst deine Aenderung NICHT ausfuehren
  und NICHT messen.
- Daraus folgt: Behaupte nie, etwas sei messbar besser. Halte Aenderungen klein,
  lokal und nachvollziehbar. Im Zweifel ist die kleinere Aenderung die richtige.
- Es ist fremder Code mit eigenem Stil (viel Kurznamen, wenig Kommentare).
  Passe dich dem an, statt ihn umzuformatieren.
`.trim();

const READ_TOOLS = [
    {
        type: "function",
        function: {
            name: "list_files",
            description: "Listet alle Dateien im Repository mit ihrer Groesse.",
            parameters: { type: "object", properties: {}, required: [] }
        }
    },
    {
        type: "function",
        function: {
            name: "read_file",
            description: "Liest einen Ausschnitt einer Datei, mit Zeilennummern. Die Userscripts sind gross - lies gezielt in Abschnitten.",
            parameters: {
                type: "object",
                properties: {
                    path: { type: "string", description: "Pfad relativ zum Repo-Wurzelverzeichnis, z.B. bot.user.js" },
                    offset: { type: "integer", description: "Erste Zeile (1-basiert). Standard 1." },
                    limit: { type: "integer", description: "Anzahl Zeilen, maximal 600. Standard 200." }
                },
                required: ["path"]
            }
        }
    },
    {
        type: "function",
        function: {
            name: "search",
            description: "Sucht ein JavaScript-Regex zeilenweise im Repository und liefert Treffer mit Pfad und Zeilennummer.",
            parameters: {
                type: "object",
                properties: {
                    pattern: { type: "string", description: "Regulaerer Ausdruck" },
                    path: { type: "string", description: "Optional: nur in dieser Datei suchen" }
                },
                required: ["pattern"]
            }
        }
    }
];

function readHandlers() {
    return {
        list_files: () => repo.listFiles().map((f) => f.path + " (" + f.bytes + " B)").join("\n"),
        read_file: (args) => {
            const file = repo.readFile(args.path, args.offset, args.limit);
            return "// " + file.path + " Zeilen " + file.firstLine + "-" + file.lastLine + " von " + file.totalLines + "\n" + file.content;
        },
        search: (args) => {
            const hits = repo.search(args.pattern, args.path);
            if (hits.length === 0) return "Keine Treffer.";
            return hits.map((h) => h.path + ":" + h.line + ": " + h.text).join("\n");
        }
    };
}

function finishTool(name, description, properties, required) {
    return {
        type: "function",
        function: { name, description, parameters: { type: "object", properties, required } }
    };
}

// --- Scout: findet Kandidaten -------------------------------------------

const scout = {
    name: "Scout",
    system: PROJECT_BRIEF + `

Du bist der Scout. Du suchst im Code nach konkreten, abgegrenzten
Verbesserungsmoeglichkeiten und schlaegst sie vor. Du aenderst nichts.

Regeln:
- Sieh dir den Code wirklich an, bevor du etwas vorschlaegst. Mindestens zwei
  read_file- oder search-Aufrufe, sonst raetst du.
- Jeder Vorschlag ist so klein, dass er in wenige Zeilen Diff passt.
- Schlage nichts vor, was laut Verlauf schon erledigt oder verworfen wurde.
- Keine reinen Geschmacksumbauten (Umformatieren, Umbenennen ohne Grund,
  "moderner machen"). Es zaehlt nur, was den Bot besser spielen laesst,
  einen echten Fehler behebt, oder die Bedienung verbessert.
- Wenn du nichts Sinnvolles findest, gib eine leere Liste zurueck. Das ist ein
  gueltiges und oft richtiges Ergebnis.`,
    tools: {
        definitions: [...READ_TOOLS, finishTool(
            "finish_scout",
            "Uebergibt die gefundenen Kandidaten.",
            {
                candidates: {
                    type: "array",
                    description: "Bis zu 4 Kandidaten. Leer, wenn nichts Sinnvolles offen ist.",
                    items: {
                        type: "object",
                        properties: {
                            title: { type: "string", description: "Eine Zeile, konkret. Nicht 'Code verbessern'." },
                            rationale: { type: "string", description: "Was ist das Problem, an welcher Stelle (Datei:Zeile)?" },
                            acceptance: { type: "string", description: "Woran erkennt man, dass es erledigt ist?" },
                            risk: { type: "string", enum: ["niedrig", "mittel", "hoch"] }
                        },
                        required: ["title", "rationale", "acceptance", "risk"]
                    }
                },
                notes: { type: "string", description: "Optional: was dir sonst aufgefallen ist." }
            },
            ["candidates"]
        )],
        handlers: readHandlers(),
        finishName: "finish_scout",
        temperature: 0.6
    }
};

// --- Critic: entscheidet, ob ueberhaupt etwas getan wird -----------------

const critic = {
    name: "Critic",
    system: PROJECT_BRIEF + `

Du bist der Critic. Der Scout hat dir Kandidaten geschickt. Du waehlst
hoechstens einen davon aus - oder du stoppst den Lauf.

Du stoppst (decision = "stop"), wenn:
- kein Kandidat einen echten Nutzen hat,
- alle Kandidaten zu riskant sind fuer Code, der nicht getestet werden kann,
- oder es nur um Kosmetik geht.

Stoppen ist ausdruecklich erwuenscht. Ein Lauf, der nichts tut, ist besser als
ein Lauf, der Beschaeftigung erfindet. Waehle niemals einen Kandidaten nur,
damit der Lauf etwas produziert.

Wenn du auswaehlst, schreibe einen Plan, der praezise genug ist, dass der
Implementer ihn ohne Rueckfragen umsetzen kann.`,
    tools: {
        definitions: [...READ_TOOLS, finishTool(
            "finish_critic",
            "Entscheidung ueber den Lauf.",
            {
                decision: { type: "string", enum: ["pick", "stop"] },
                reason: { type: "string", description: "Begruendung der Entscheidung, ein bis drei Saetze." },
                title: { type: "string", description: "Nur bei 'pick': Titel des gewaehlten Vorhabens." },
                plan: { type: "string", description: "Nur bei 'pick': konkreter Umsetzungsplan mit Datei und Stelle." },
                acceptance: { type: "string", description: "Nur bei 'pick': Abnahmekriterium." }
            },
            ["decision", "reason"]
        )],
        handlers: readHandlers(),
        finishName: "finish_critic",
        temperature: 0.2
    }
};

// --- Implementer: schreibt den Patch ------------------------------------

function implementer(stage) {
    return {
        name: "Implementer",
        system: PROJECT_BRIEF + `

Du bist der Implementer. Du setzt genau das um, was der Critic beauftragt hat -
nicht mehr. Kein Aufraeumen nebenbei, keine zusaetzlichen Verbesserungen.

Vorgehen:
1. Lies die betroffene Stelle mit read_file, bis du sie wirklich kennst.
2. Rufe propose_edit auf, einmal pro Aenderung.
3. Rufe finish_implement auf.

Zu propose_edit:
- 'search' muss exakt so im aktuellen Dateiinhalt stehen: gleiche Einrueckung,
  gleiche Zeilenumbrueche, keine Zeilennummern. Die Zeilennummern aus read_file
  sind nur Anzeige und gehoeren NICHT in 'search'.
- 'search' muss eindeutig sein. Ist der Ausschnitt mehrdeutig, nimm mehr
  Kontextzeilen dazu.
- Schlaegt ein Aufruf fehl, bekommst du den Fehler zurueck und versuchst es
  korrigiert erneut.`,
        tools: {
            definitions: [
                ...READ_TOOLS,
                {
                    type: "function",
                    function: {
                        name: "propose_edit",
                        description: "Merkt eine Aenderung vor. Es wird noch nichts geschrieben - der Reviewer sieht sie zuerst.",
                        parameters: {
                            type: "object",
                            properties: {
                                path: { type: "string" },
                                search: { type: "string", description: "Exakter, eindeutiger Textausschnitt aus der Datei." },
                                replace: { type: "string", description: "Der Text, der ihn ersetzt." },
                                note: { type: "string", description: "Ein Satz: warum diese Aenderung." }
                            },
                            required: ["path", "search", "replace"]
                        }
                    }
                },
                finishTool(
                    "finish_implement",
                    "Schliesst die Umsetzung ab.",
                    {
                        summary: { type: "string", description: "Was wurde geaendert und warum." },
                        commitMessage: { type: "string", description: "Commit-Betreff, englisch, Imperativ, hoechstens 72 Zeichen." }
                    },
                    ["summary", "commitMessage"]
                )
            ],
            handlers: {
                ...readHandlers(),
                propose_edit: (args) => {
                    repo.validateEdit(args, stage.allowedPaths);
                    stage.edits.push({ path: args.path, search: args.search, replace: args.replace, note: args.note || "" });
                    return "Aenderung vorgemerkt (" + stage.edits.length + " insgesamt) in " + args.path + ".";
                }
            },
            finishName: "finish_implement",
            temperature: 0.1
        }
    };
}

// --- Reviewer: prueft den Patch -----------------------------------------

const reviewer = {
    name: "Reviewer",
    system: PROJECT_BRIEF + `

Du bist der Reviewer. Du pruefst den Patch des Implementers gegen den Auftrag
des Critics. Du aenderst selbst nichts.

Pruefe:
- Tut der Patch, was beauftragt wurde, und nur das?
- Ist er syntaktisch plausibles JavaScript im Stil der Datei?
- Bricht er etwas, das an anderer Stelle davon abhaengt? Pruefe das mit search,
  statt es zu vermuten.
- Wird eine Variable benutzt, die es an dieser Stelle gar nicht gibt?

Sei streng, aber nicht kleinlich: Stilfragen sind kein Ablehnungsgrund. Lehne
ab, wenn der Patch falsch, gefaehrlich oder ueber den Auftrag hinaus ist.
Jeder Einwand muss so konkret sein, dass der Implementer ihn direkt beheben kann.`,
    tools: {
        definitions: [...READ_TOOLS, finishTool(
            "finish_review",
            "Ergebnis des Reviews.",
            {
                approved: { type: "boolean" },
                objections: {
                    type: "array",
                    description: "Bei approved=false: je Einwand ein konkreter, umsetzbarer Satz.",
                    items: { type: "string" }
                },
                comment: { type: "string", description: "Kurze Gesamteinschaetzung." }
            },
            ["approved", "comment"]
        )],
        handlers: readHandlers(),
        finishName: "finish_review",
        temperature: 0.2
    }
};

// --- Curator: schreibt das Gedaechtnis fort ------------------------------

const curator = {
    name: "Curator",
    system: PROJECT_BRIEF + `

Du bist der Curator. Du schreibst das Gedaechtnis des Projekts fort, damit der
naechste Lauf nicht bei null anfaengt und nicht dasselbe nochmal vorschlaegt.

- 'journal' ist ein kurzer Absatz: was ist in diesem Lauf passiert, was wurde
  bewusst nicht getan.
- 'backlogAdditions' sind Vorhaben, die waehrend des Laufs aufgefallen sind,
  aber nicht Teil davon waren. Lieber keine als erfundene. Leere Liste ist
  ein voellig normales Ergebnis.`,
    tools: {
        definitions: [finishTool(
            "finish_curate",
            "Schreibt Journal und Backlog fort.",
            {
                journal: { type: "string", description: "Ein Absatz Fliesstext." },
                backlogAdditions: {
                    type: "array",
                    items: {
                        type: "object",
                        properties: {
                            title: { type: "string" },
                            rationale: { type: "string" },
                            acceptance: { type: "string" }
                        },
                        required: ["title", "rationale"]
                    }
                }
            },
            ["journal"]
        )],
        handlers: {},
        finishName: "finish_curate",
        temperature: 0.3
    }
};

module.exports = { PROJECT_BRIEF, scout, critic, implementer, reviewer, curator };
