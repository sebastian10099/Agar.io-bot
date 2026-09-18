// Minimal OpenRouter client. No dependencies, uses Node's built-in fetch (Node 18+).

const BASE_URL = process.env.OPENROUTER_BASE_URL || "https://openrouter.ai/api/v1";

function apiKey() {
    const key = process.env.OPENROUTER_API_KEY;
    if (!key) {
        throw new Error(
            "OPENROUTER_API_KEY ist nicht gesetzt.\n" +
            "  export OPENROUTER_API_KEY=sk-or-...\n" +
            "Key erstellen: https://openrouter.ai/keys"
        );
    }
    return key;
}

function headers() {
    return {
        "Authorization": "Bearer " + apiKey(),
        "Content-Type": "application/json",
        // Optional, shows up in the OpenRouter dashboard so runs are attributable.
        "HTTP-Referer": process.env.OPENROUTER_SITE_URL || "https://github.com/Apostolique/Agar.io-bot",
        "X-Title": process.env.OPENROUTER_APP_TITLE || "Agar.io-bot agents"
    };
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Retries on rate limits and transient server errors with exponential backoff.
async function request(path, body, { retries = 4 } = {}) {
    let delay = 2000;
    let lastError = null;

    for (let attempt = 0; attempt <= retries; attempt++) {
        let response;
        try {
            response = await fetch(BASE_URL + path, {
                method: "POST",
                headers: headers(),
                body: JSON.stringify(body)
            });
        } catch (err) {
            lastError = err;
            if (attempt === retries) break;
            await sleep(delay);
            delay *= 2;
            continue;
        }

        if (response.ok) return response.json();

        const text = await response.text();
        lastError = new Error("OpenRouter " + response.status + ": " + text.slice(0, 500));

        // 4xx other than 429 will not get better by retrying.
        if (response.status !== 429 && response.status < 500) throw lastError;
        if (attempt === retries) break;

        await sleep(delay);
        delay *= 2;
    }

    throw lastError;
}

async function listModels() {
    const response = await fetch(BASE_URL + "/models", { headers: headers() });
    if (!response.ok) {
        throw new Error("Modellliste nicht abrufbar (" + response.status + ").");
    }
    const payload = await response.json();
    return (payload.data || []).map((m) => m.id);
}

// One chat completion. Returns { message, usage, cost }.
async function chat({ model, messages, tools, temperature = 0.3, maxTokens = 4096 }) {
    const body = {
        model,
        messages,
        temperature,
        max_tokens: maxTokens,
        usage: { include: true }
    };
    if (tools && tools.length > 0) {
        body.tools = tools;
        body.tool_choice = "auto";
    }

    const payload = await request("/chat/completions", body);

    if (payload.error) {
        throw new Error("OpenRouter: " + (payload.error.message || JSON.stringify(payload.error)));
    }
    const choice = payload.choices && payload.choices[0];
    if (!choice) {
        throw new Error("OpenRouter lieferte keine Antwort: " + JSON.stringify(payload).slice(0, 300));
    }

    const usage = payload.usage || {};
    return {
        message: choice.message,
        finishReason: choice.finish_reason,
        usage,
        // OpenRouter reports the real price of the call when usage accounting is on.
        cost: typeof usage.cost === "number" ? usage.cost : 0
    };
}

module.exports = { chat, listModels, BASE_URL };
