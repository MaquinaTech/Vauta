# Model servers

Vauta uses language models for three things: **live notes** while you record, **minutes** after a meeting, and
**Ask** (answers with citations). It can also use an **embedding model** for "Search by meaning", which helps Ask find
the right passages. Transcription never uses these models; it always runs on Apple's on-device speech recognition.

You choose where the models run in **Settings → Models → Write minutes with**:

| Choice | Setup | Text leaves this Mac? |
|---|---|---|
| **Apple Intelligence on this Mac** | None | No |
| **A model server on this Mac** | Install and start a server app (LM Studio, Ollama…) | No. Only `127.0.0.1`, `::1` or `localhost` are accepted |
| **A model server on your network** | A server on another computer, behind HTTPS | Yes, to that computer only, encrypted with TLS 1.3. Only private network addresses are accepted |

New installations start with Apple Intelligence (*Quick start · Basic quality*) and keyword search for Ask. Vauta talks to servers through the **OpenAI-compatible API**
(`/v1/models`, `/v1/chat/completions`, `/v1/embeddings`), so any server that offers it can work.

## Guided setup

**Settings → Models → Set Up…** (also offered in the first-run setup, on its last page, and from the "Set Up…" button next to minutes written on-device) walks you through a model server on this Mac in four steps (with Ollama, whose download command needs its app open, steps 2 and 3 swap places: open Ollama, then download the model). In the first-run setup the guide opens over the setup window; on a Mac with less than 16 GB it only explains the options, and a server on another computer is connected later in **Settings → Models**. Vauta does not run models itself and does not download anything: it shows what to install, opens the app's website, and watches for the server.

1. **Install the app.** LM Studio (recommended: its MLX engine runs on every Apple silicon Mac) or Ollama. Vauta finds an installed app through macOS (by bundle identifier, falling back to the app's name in `/Applications` and `~/Applications`) and offers **Open**; otherwise **Get** opens the official website in your browser.
2. **Download the model that fits this Mac.** Only models the project evaluated are suggested, chosen from the Mac's memory:

   | Memory | Suggestion | Download |
   |---|---|---|
   | Under 16 GB | None. The guide explains why and suggests keeping Apple Intelligence (when the Mac has it), or a server on another computer | |
   | 16–31 GB | Qwen3.5-9B for both roles | about 7 GB |
   | 32 GB or more | Qwen3.8-27B as the main model and Qwen3.5-9B as the fast model, or **one model only** (the 27B) | about 16–18 GB, plus about 7 GB for the 9B |

   The guide shows the exact command per app with a **Copy** button (the commands go in Terminal; `lms` and `ollama` work once their app has been opened), and the free disk space (with a warning when the download plus 5 GB would not fit, and what to do about it: the single model if that fits, or how much to free, with a button that opens Storage settings). Finished steps collapse to their title; click one to open it again. How to load the model with a context of at least 32K tokens is shown in step 3, next to starting the server:

   | | LM Studio | Ollama |
   |---|---|---|
   | Download Qwen3.5-9B | `lms get qwen/qwen3.5-9b` | `ollama pull qwen3.5:9b` |
   | Download Qwen3.8-27B | `lms get qwen/qwen3.8-27b` | `ollama pull qwen3.8:27b` |
   | Context | `lms load <model> --context-length 32768` (for a model already loaded with less, the guide shows `lms unload <model> && lms load …`) | Settings → Context length slider (Ollama's default depends on GPU memory and is 4k under 24 GiB) |
   | Start the server | Developer tab, or `lms server start` | Runs by itself while its app is open |

   You can also search for the model's name in each app's model browser. Embedding models are not part of the guide: Ask keeps using keyword search, which needs no model.
3. **Start the server and set the context.** While the guide is open, Vauta checks this Mac every few seconds (see [How detection works](#how-detection-works)) and shows what it sees: waiting for the server, server running without the model, the model loaded with too little context (the status strip says so and **Show Fix** scrolls to the outlined command), or found and ready.
4. **Use the model.** **Use This Model** saves a local server configuration (address, server type, both model roles, context), tests the connection, and switches **Write minutes with** to the server. Ollama reports a model's context only while the model is running: when it isn't known yet, the guide asks the server again right after the connection test (the same read-only requests), and if the context turns out to be under 32K it doesn't finish: your previous settings are put back and the guide shows the fix instead. **Search by meaning** stays as you had it, unless it needed an embedding model the new server lacks, in which case Ask uses keyword search. A saved key is never sent to a different destination: if the address changed, the key is removed, as in **Save**.

The model identifiers above were checked against the [Ollama library](https://ollama.com/library/qwen3.5), the [LM Studio model catalog](https://lmstudio.ai/models/qwen3.5) and the [LM Studio CLI documentation](https://lmstudio.ai/docs/cli). LM Studio picks the build for your Mac when you run `lms get`; choose the MLX 4-bit one if it asks.

## Roles

A server configuration names three models:

| Role | Used for | Advice |
|---|---|---|
| **Fast model** | Live notes while recording, and Ask during a recording | Small and quick. Reasoning ("thinking") is turned off for it |
| **Main model** | Minutes and Ask | The best model the computer can run. For one-request minutes Vauta allows brief reasoning (`low` effort) |
| **Translation model** | Improving Live Translation captions (**Settings → Translation**) | Defaults to the fast model. Qwen3.5-9B is a sensible choice. The refined caption replaces Apple's only if the answer arrives within Vauta's 4 s budget, so a model that is too slow, such as a 27B one, makes the captions keep Apple's translation; **Test** reports the real latency. Small dedicated translation models are not recommended: they were not better in our early, unpublished trials. It is not a separate server role: pick any model the server lists, or leave it on the fast model |
| **Model for search by meaning** | Search by meaning (an embedding model) | A multilingual embedding model, at least 256 dimensions |

The **Test** button in **Settings → Translation** translates a sample sentence with the chosen translation model and shows the
real latency, so you can tell whether it is quick enough to improve live captions.

The fast and main model can be the same. The **Context length** (8K to 256K tokens) must match the context length the server
actually loads the chat models with; Vauta fills it in when the server reports it. Meetings that don't fit in one
request are summarized in blocks and then combined.

**Ask finds passages with** (search by meaning) can be **Search by meaning on this Mac** (the optional search model, [below](#search-by-meaning-on-this-mac)), **Search by meaning (model server)**, or **Keyword search**. Ask always works with keyword search. Without a server, new installations use keyword search
only, because it needs no model and nothing to download; a choice you saved is never changed, and installs
that already had a server keep using its embedding model. If you change the embedding model, Vauta computes the vectors again.

The **Model for search by meaning** field appears, and is required, only when **Ask finds passages with** is set to **Search by meaning (model server)**. Configurations saved
before this change keep their embedding model name unchanged.

## Which quality to expect

We do not quote minute-quality or search scores: the early comparisons we ran used data that is not in this repository, so they cannot be reproduced (see [CLAIMS.md](CLAIMS.md)). The direction is that Apple's on-device model has a small context window and a larger model on a server usually writes better minutes; try both on your own meetings.

In practice: Apple Intelligence is the zero-setup way to try Vauta. For minutes you will rely on, connect a server with a
9B or larger model (a 27B model if the Mac has the memory), and let it reason on long meetings. Vauta shows a dismissible recommendation next to minutes written on-device; it never blocks anything.

## Apple Intelligence on this Mac

- **Requirements:** a Mac that supports Apple Intelligence, with Apple Intelligence turned on in System Settings and
  its model downloaded, and a language the model supports.
- **No setup and nothing leaves the Mac.** Vauta uses only the on-device model, never Private Cloud Compute.
- **Limits:** the context length is small (4,096 tokens on macOS 26). Vauta adapts: minutes are written block by block
  and combined, live notes look at a shorter window, and Ask reads fewer passages. Minutes are shorter, less
  detailed and less reliable than with a large model (see [Which quality to expect](#which-quality-to-expect)).
- Apple's own on-device embeddings were removed: they found passages worse than keyword search. **Search by meaning on this Mac** now uses the optional search model described in the next section.

Status messages and what to do:

| Message | Meaning |
|---|---|
| This Mac cannot run Apple Intelligence. | Choose a model server |
| Apple Intelligence is turned off. | Turn it on in System Settings, or choose a model server |
| Apple's on-device model is still downloading. | Vauta uses it as soon as the download finishes |
| The on-device model does not support this language. | Use a model server for meetings in this language |

## Search by meaning on this Mac

**Search by meaning on this Mac** needs no model server and no embedding model on one. It uses **EmbeddingGemma 2** by Google, an
optional download of 574 MB for Apple silicon (Settings → Models → **Download**, or **Import from a File…**). It runs on this Mac's
GPU and searches meetings and documents in any language and across languages ([SEARCH_MODEL.md](SEARCH_MODEL.md) has the design, the measurements so far and their limits). While your library is being indexed for the first time,
and without the model, Ask uses keyword search; the label under the question says which.

A **model server's embeddings** still make sense when you already run an embedding model you prefer, when this Mac is not
Apple silicon, or when you want the vectors computed on a bigger computer. They keep working as before (BM25 and vectors fused);
the exact-match boost and the Gemma-first ranking apply only to the search model.

## A server on this Mac

1. Install and start one of the servers below. Make sure it listens on `127.0.0.1` only.
2. In **Settings → Models**, choose **A model server on this Mac** and click **Find Model Servers**.
3. Pick the detected server. Vauta fills in the address, the server type, the models and the context length.
4. Check the models, click **Test Connection**, then **Save**.

### How detection works

Detection runs when you click **Find Model Servers**, and, while the guided setup is open, every few seconds for LM Studio's and Ollama's ports only (1234 and 11434); it stops when the guide closes, the window is hidden or Meetings relocks. Vauta sends read-only requests (`GET`, plus Ollama's
`POST /api/show`) to `http://127.0.0.1` on the usual ports and never to any other address:

| Port | Servers |
|---|---|
| 1234 | LM Studio |
| 11434 | Ollama |
| 8080 | llama.cpp, LocalAI, MLX (`mlx-lm`) |
| 8000 | vLLM |
| 1337 | Jan |

For each port that answers `/v1/models`, Vauta identifies the server from its read-only endpoints:

| Server | Identified by | Context length reported |
|---|---|---|
| Ollama | `/api/version`; models from `/api/tags`, `/api/show`, `/api/ps` | `num_ctx` in the model's Modelfile, or the context length of a loaded model |
| LM Studio | `/api/v0/models` (model type and state) | The loaded context length |
| llama.cpp | `/props` | `n_ctx` |
| Jan | Port 1337 (it answers `/props` like llama.cpp) | `n_ctx` |
| vLLM | `/version`, or `owned_by: vllm` | `max_model_len` |
| LocalAI | `/version` (when the models don't look like vLLM's) | No |
| MLX | Model names containing "mlx" | No |

A server on another port, or on `::1`, is not found automatically: type its address (for example
`http://127.0.0.1:5000/v1`) and click **Test Connection**.

### Server types and request options

Each server type sets how Vauta asks for reasoning on or off, and whether it requests structured JSON output. You can
change them under **Settings → Models → Advanced**.

| Server type | Thinking control | Structured output |
|---|---|---|
| LM Studio | Don't send | JSON schema |
| Ollama | Ollama think | JSON schema |
| llama.cpp | `chat_template_kwargs` | JSON schema |
| vLLM | `chat_template_kwargs` | JSON schema |
| MLX | `chat_template_kwargs` | Off |
| LocalAI | Don't send | JSON object |
| Jan, OpenAI-compatible server | Don't send | Off |
| Original format (version 0.1) | `enable_thinking` at the root | Off |

What each thinking control sends:

| Option | Thinking off | Thinking on (one-request minutes) |
|---|---|---|
| `enable_thinking` at the root | `"enable_thinking": false` | `"enable_thinking": true, "reasoning_effort": "low"` |
| `chat_template_kwargs` | `"chat_template_kwargs": {"enable_thinking": false}` | `{"enable_thinking": true}` and `"reasoning_effort": "low"` |
| `reasoning_effort` (gpt-oss style) | `"reasoning_effort": "low"` | `"reasoning_effort": "low"` |
| Ollama think | `"think": false, "reasoning_effort": "none"` | `"think": true, "reasoning_effort": "low"` |
| Don't send | nothing | nothing |

**Sampling** is "Server default" for every type except "Original format (version 0.1)", which sends Qwen's recommended
values (temperature 0.7, top_p 0.8, top_k 20) when thinking is off. Vauta strips reasoning that a server returns inside
the answer (`<think>…</think>` and similar).

**Ask and structured output.** When the server's structured output is "JSON schema", Ask sends the shape of its answer as a
`response_format`: `found` (true or false), `answer` and `claims`, where `found: true` needs at least one claim with at least one
citation and `found: false` has none. The schema never lists the passages that were sent; Vauta checks the citations and the quotes
itself, whatever the server does, and shows an answer whose claims fail the check as unverified (not as "not found"). With "JSON
object" or "Off" the same shape is asked for in the prompt and checked the same way.

If the server rejects requests (HTTP 400) after you change models, set **Thinking control** to "Don't send" and
**Structured output** to "Off", then test again. If live notes are slow because the model keeps reasoning, choose a
thinking control the server understands, or use an instruct (non-reasoning) model as the fast model.

## Servers

### LM Studio

- Start the server in LM Studio's Developer tab (or `lms server start`). Default port **1234**. Keep "Serve on Local
  Network" off for a server on this Mac.
- Load models with enough context, for example `lms load <model> --context-length 32768`. Vauta reads the loaded
  context length.
- LM Studio lists chat and embedding models separately, so Vauta suggests all three roles.
- There is no per-request switch for reasoning. For the fast role, pick an instruct model or turn reasoning off in
  the model's settings in LM Studio, if it offers that.

### Ollama

- Default address `127.0.0.1:11434`. Pull models with `ollama pull`.
- **Set the context length.** Ollama's default context length is too small for Vauta (which needs at least 8K, and works best
  with 32K). Either set it for the whole server (the context length setting in the Ollama app, or the
  `OLLAMA_CONTEXT_LENGTH=32768` environment variable for `ollama serve`), or create a model with it:

  ```
  FROM qwen3:8b
  PARAMETER num_ctx 32768
  ```

  `ollama create qwen3-8b-32k -f Modelfile`. Vauta reads `num_ctx` from the Modelfile and the context length of loaded
  models. If Vauta's Context length is larger than what Ollama loads, Ollama may cut the prompt without an error.
- Embedding models (for example `qwen3-embedding:0.6b` or `bge-m3`) are recognized from Ollama's model capabilities.

### llama.cpp (`llama-server`)

```sh
llama-server -m Qwen3-8B-Q4_K_M.gguf -c 32768 --jinja --host 127.0.0.1 --port 8080
```

- `--jinja` is needed for `chat_template_kwargs` (thinking control) to work.
- One `llama-server` serves one model. For embeddings, start a second one with an embedding model and `--embedding`
  (and the pooling its model card recommends) on another port, and point the embedding role at it (see
  [Separate servers per role](#separate-servers-per-role)). Or set **Ask finds passages with** to **Search by meaning on this Mac** (it downloads the optional search model).

### MLX (`mlx-lm`)

```sh
pip install mlx-lm
mlx_lm.server --model mlx-community/Qwen3-8B-4bit --host 127.0.0.1 --port 8080
```

- Detected on port 8080 when a model name contains "mlx". Set **Context length** by hand: the server does not report it.
- `mlx_lm.server` has no embeddings endpoint. Set **Ask finds passages with** to **Search by meaning on this Mac** (it downloads the optional search model), or use another server for the embedding
  role (for example Ollama), see [Separate servers per role](#separate-servers-per-role).

### vLLM

```sh
vllm serve Qwen/Qwen3-8B --max-model-len 32768 --host 127.0.0.1 --port 8000
```

- vLLM listens on all interfaces by default: pass `--host 127.0.0.1` (or put it behind the TLS proxy described below
  when it runs on another computer, which is the usual case for GPU servers).
- One process serves one model. Run the embedding model as a second vLLM process in embedding (pooling) mode on
  another port, see vLLM's documentation for the flag in your version, and use
  [separate servers per role](#separate-servers-per-role).
- `--api-key` sets a key; enter the same key in Vauta.

### Jan

- Turn on the local API server in Jan's settings. Default port **1337**. If you set an API key in Jan, enter it as
  Vauta's key.
- Thinking control defaults to "Don't send".

### LocalAI

- Default port **8080**. Make sure it listens on `127.0.0.1` only (check its address setting).
- Structured output defaults to "JSON object". LocalAI can serve embedding models too.

## Separate servers per role

Each role can have its own base URL, for example chat on MLX and embeddings on Ollama. The form does not edit this yet;
use **Settings → Models → Advanced → Paste Configuration** with JSON like this (the key is never part of it):

```json
{
  "mode": "local",
  "baseURL": "http://127.0.0.1:8080/v1",
  "fastModel": "mlx-community/Qwen3-4B-Instruct-2507-4bit",
  "deepModel": "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
  "embeddingModel": "qwen3-embedding:0.6b",
  "contextTokens": 32768,
  "profile": { "kind": "mlx" },
  "roleBaseURLs": { "embedding": "http://127.0.0.1:11434/v1" }
}
```

Review the result, click **Test Connection**, then **Save**. Role URLs follow the same rules as the main address
(loopback for this Mac; HTTPS and private addresses for the network). The same key, if any, is sent to every role URL.
The server status check and Test Connection read the model list from the main address and from every role URL that is
set, so a model served from a role URL is not reported missing.

Optional `embedding` settings: `"embedding": {"dimensions": 1024, "matryoshka": true, "family": "qwen3"}`. Vauta
recognizes the query and document prefixes of Qwen3-Embedding, e5, multilingual-e5-instruct, nomic-embed-text,
mxbai-embed-large, arctic-embed and EmbeddingGemma from the model name, and cuts Matryoshka models' vectors to 1024
dimensions unless you say otherwise.

## Recommended models

These are starting points, not guarantees. Choose models that write well in your meeting languages, and leave memory
for macOS, the context (the KV cache grows with it) and your other apps. Sizes assume 4-bit quantization.

| Memory | Fast model | Main model | Model for search by meaning |
|---|---|---|---|
| 16 GB | Qwen3-4B-Instruct-2507 | Qwen3-8B, or the same 4B model | Qwen3-Embedding-0.6B, bge-m3 |
| 24–32 GB | Qwen3-4B-Instruct-2507 | Qwen3-30B-A3B-Instruct-2507, gpt-oss-20b, Gemma 3 27B | Qwen3-Embedding-0.6B, bge-m3 |
| 64 GB | Qwen3-4B-Instruct-2507 or Qwen3-30B-A3B | Qwen3-32B, Qwen3-30B-A3B at 8-bit | Qwen3-Embedding-4B, bge-m3 |
| 96 GB or more | Qwen3-30B-A3B-Instruct-2507 | gpt-oss-120b, larger mixture-of-experts models | Qwen3-Embedding-4B or 8B |

- Qwen3, Gemma 3 and gpt-oss handle many languages. Check yours before relying on it.
- For embeddings, prefer multilingual models (Qwen3-Embedding, bge-m3, multilingual-e5, EmbeddingGemma).
  `nomic-embed-text` and `mxbai-embed-large` work best in English.
- For gpt-oss, set **Thinking control** to `reasoning_effort`.
- A context of 32K is a good default. Larger contexts let long meetings be summarized in one request, at the cost of
  memory and time.

On a modest Mac, minutes can take from a few minutes to more than half an hour per hour of meeting. Vauta writes them
in the background after the meeting and notifies you when they are ready.

## A server on another computer

Vauta reaches other computers only over **HTTPS with TLS 1.3**, and only at private addresses (`10.x`, `172.16–31.x`,
`192.168.x`, `100.64–127.x` such as Tailscale, link-local, IPv6 `fc00::/7` and `fe80::/10`) or local names (`.local`,
`.lan`, `.home.arpa`, `.internal`, `.ts.net`). A host given by name also needs a private CA or a certificate pin,
because a name could resolve anywhere. Proxies and redirects are refused. See
[SECURITY.md](../SECURITY.md#network-policy) for all the rules.

Most model servers don't speak HTTPS themselves, so the usual setup is: the model server on `127.0.0.1` of the server
computer, and a TLS proxy (such as Caddy) in front of it.

### 1. Give the server a fixed address

Reserve its IP address in your router (DHCP reservation), for example `192.168.1.50`. A `.local` name works too, but
then the private CA or a pin is mandatory.

### 2. Create a private CA and a certificate

On your Mac, from a checkout of this repository:

```sh
./scripts/make-server-cert.sh 192.168.1.50 server.local
```

The arguments are the addresses and names Vauta will use; they go into the certificate and must match the URL in
Settings. The script writes to `./vauta-server-tls/` (or `$VAUTA_TLS_DIR`):

| File | What to do with it |
|---|---|
| `ca.key` | The CA's private key. Keep it off the server and out of cloud backups |
| `ca.crt` | Import it in Vauta (Settings → Models → Private certificate authority → Import…) |
| `server.key` | Copy it to the server (only readable by the proxy) |
| `server.crt` | Copy it to the server. Valid 800 days |

The script also prints the server's **pin** (SHA-256 of its public key). To renew, run it again with the same
arguments: it reuses the CA and the server key, so the pin doesn't change.

### 3. Put Caddy in front of the model server

Example `Caddyfile` on the server, for Ollama on `127.0.0.1:11434` with a key:

```caddyfile
https://192.168.1.50:8443 {
	tls /etc/vauta/server.crt /etc/vauta/server.key {
		protocols tls1.3
	}

	@unauthorized {
		not header Authorization "Bearer {$VAUTA_SERVER_KEY}"
	}
	respond @unauthorized 401

	reverse_proxy 127.0.0.1:11434 {
		header_up Host {upstream_hostport}
		flush_interval -1
	}
}
```

Start it with the key in the environment, for example `VAUTA_SERVER_KEY="$(cat /etc/vauta/key)" caddy run`.
`flush_interval -1` passes the streamed answer through as it arrives. Change the upstream port for other servers
(1234 for LM Studio, 8080 for llama.cpp or `mlx-lm`, 8000 for vLLM).

### 4. Firewall

Expose only the proxy port, and only to your network:

- **macOS server:** System Settings → Network → Firewall: on; allow incoming connections for Caddy only. Keep the
  model server bound to `127.0.0.1`.
- **Linux server** (ufw): `sudo ufw allow from 192.168.1.0/24 to any port 8443 proto tcp`, and nothing for the model
  server's own port.

### 5. A key for Vauta

Create a key used only by Vauta, for example with `openssl rand -base64 32`. Keys are printable ASCII without spaces,
up to 512 characters. Enter it in Settings → Models → Key. Vauta keeps it in your Keychain (`llm-bearer-v1`), never
shows it again, and sends it only to the saved server. If you change the server's mode, address, CA or pins and click
Save, Vauta removes the saved key instead of sending it to the new destination; enter the key for the new server.

### 6. Configure Vauta

1. **Settings → Models → A model server on your network.**
2. Address: `https://192.168.1.50:8443/v1`.
3. **Private certificate authority → Import…** and choose `ca.crt`. With a CA, it is the only authority Vauta trusts.
4. Optionally add the server's pin: under **Certificate pins**, click **Choose File…** (or **Paste Certificate**) with
   the server's certificate, and Vauta computes the pin and adds it. Separate several pins with commas (for example the current and
   the next key during a rotation).
5. Enter the key, click **Test Connection**, choose the models, then **Save**.

Outside the app, you can compute the pin of any certificate with:

```sh
openssl x509 -in server.crt -pubkey -noout | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64
```

### Check a configuration from the command line

`Vauta server-check config.json [--ask-key]` lists the server's models, sends a short test prompt to the fast and main
models, and requests one embedding. `config.json` uses the same JSON as Paste Configuration. Build the command-line
tool from a checkout (`swift build -c release`, then `.build/release/Vauta server-check config.json`), because the
installed app is sandboxed and cannot read files you name on the command line.

## Troubleshooting

| Message | What to do |
|---|---|
| No server found. Open LM Studio, Ollama… | Start the server, check it listens on `127.0.0.1` and its usual port, or type its address |
| "A model server on this Mac" only accepts 127.0.0.1, ::1 or localhost. | For another computer, choose "A model server on your network" |
| A model server on your network must be reached over HTTPS… | Use `https://` and a TLS proxy (see above) |
| "…" is not a local network address… | Use the server's private IP address or a local name. Vauta never sends meetings to the internet |
| "…" is a name, which could resolve outside your network… | Import the private CA or add a pin, or use the IP address |
| Can’t reach the model server: connection refused (invalid certificate or destination) | The certificate doesn't match: wrong CA, the address isn't in the certificate (rerun `make-server-cert.sh` with it), the pin doesn't match, the server offers TLS older than 1.3, or it redirects |
| Can’t reach the model server: … | The server isn't running, the port is wrong, or a firewall blocks it |
| The model server name resolved to …, which is not on your local network. | The name points outside your network. Fix DNS or use the IP address, then apply the settings again |
| The model server rejected the key. | Enter the key again in Settings → Models |
| The model server does not have the selected model. / The server doesn't list: … | Download or load the model, or pick one from the list after Test Connection |
| The text is too long for the model's context length. | Load the model with a longer context length on the server, or lower Context length in Vauta |
| The model's answer was cut off at the length limit. | Use a longer context length, or a model that reasons less |
| The model server answered 400: … | Usually an option the server doesn't accept: under Advanced, set Thinking control to "Don't send" or Structured output to "Off" |
| The model server sent an invalid response (…). | Try another Structured output option, or another model |
| The embedding model returns N dimensions; Vauta needs at least M. | Pick another embedding model |
| The model server is busy. Retrying in N s. | Nothing: Vauta retries. Background jobs pause while the server is busy |
| The Keychain is locked… | Unlock your Mac; Vauta tries again |
| Can't reach the model server (notification while recording) | Recording continues; the minutes are written when the server is back |

`Vauta doctor` checks the speech languages, the store, the model server and the permissions in one go.

## Links to earlier meetings

Not measured on a model server and no server check is built: a server's minutes feed only the deterministic links, and only if those pass their gates on both Apple and integrated minutes.
