// The agent loop: talk to the model, run the tools it asks for, repeat
// until it calls finish() or hits its step limit.

const openrouter = require("./openrouter");

class BudgetExceeded extends Error {}

// Small budgets would round away to $0.00 with two decimals.
function formatUsd(value) {
    return value < 0.01 ? value.toFixed(4) : value.toFixed(2);
}

function makeBudget(limitUsd) {
    return {
        limitUsd,
        spentUsd: 0,
        add(cost) {
            this.spentUsd += cost || 0;
            if (this.limitUsd > 0 && this.spentUsd > this.limitUsd) {
                throw new BudgetExceeded(
                    "Budget aufgebraucht: $" + this.spentUsd.toFixed(4) + " von $" + formatUsd(this.limitUsd) +
                    ". Lauf beendet, nichts angewendet."
                );
            }
        }
    };
}

function parseArguments(raw) {
    if (!raw) return {};
    if (typeof raw === "object") return raw;
    try {
        return JSON.parse(raw);
    } catch (err) {
        throw new Error("Die Argumente sind kein gueltiges JSON: " + err.message);
    }
}

async function runAgent({ name, model, system, task, toolset, maxSteps = 14, budget, log }) {
    const messages = [
        { role: "system", content: system },
        { role: "user", content: task }
    ];

    let nudged = false;

    for (let step = 1; step <= maxSteps; step++) {
        const response = await openrouter.chat({
            model,
            messages,
            tools: toolset.definitions,
            temperature: toolset.temperature ?? 0.3
        });
        budget.add(response.cost);

        const message = response.message;
        messages.push(message);

        const calls = message.tool_calls || [];

        if (calls.length === 0) {
            // Model answered in prose. Give it exactly one reminder, then give up.
            if (nudged) {
                throw new Error(
                    "Agent '" + name + "' hat " + toolset.finishName + "() nicht aufgerufen. " +
                    "Letzte Antwort: " + String(message.content || "").slice(0, 400)
                );
            }
            nudged = true;
            log("  " + name + ": Antwort ohne Tool-Aufruf, erinnere an " + toolset.finishName + "()");
            messages.push({
                role: "user",
                content: "Bitte antworte nicht in Prosa. Rufe das Tool " + toolset.finishName + " mit deinem Ergebnis auf."
            });
            continue;
        }

        let finished = null;

        for (const call of calls) {
            const toolName = call.function && call.function.name;
            let output;

            try {
                const args = parseArguments(call.function && call.function.arguments);

                if (toolName === toolset.finishName) {
                    finished = args;
                    output = "OK";
                } else {
                    const handler = toolset.handlers[toolName];
                    if (!handler) throw new Error("Unbekanntes Tool: " + toolName);
                    output = await handler(args);
                    if (typeof output !== "string") output = JSON.stringify(output);
                }

                log("  " + name + " -> " + toolName + "(" + summarizeArgs(call.function.arguments) + ")");
            } catch (err) {
                // Tool errors go back to the model as a result, not as a crash:
                // a wrong search string should be fixable by the agent itself.
                output = "FEHLER: " + err.message;
                log("  " + name + " -> " + toolName + " FEHLER: " + err.message);
            }

            messages.push({
                role: "tool",
                tool_call_id: call.id,
                content: String(output).slice(0, 20000)
            });
        }

        if (finished) {
            return { result: finished, steps: step, transcript: messages };
        }
    }

    throw new Error("Agent '" + name + "' hat nach " + maxSteps + " Schritten nicht abgeschlossen.");
}

function summarizeArgs(raw) {
    const text = typeof raw === "string" ? raw : JSON.stringify(raw || {});
    return text.length > 120 ? text.slice(0, 117) + "..." : text;
}

module.exports = { runAgent, makeBudget, BudgetExceeded, formatUsd };
