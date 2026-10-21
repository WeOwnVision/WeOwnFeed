<div align="center">

# WeOwnFeed (WOF)
### **Own your feed. Every story, with receipts.**

*An algorithmic-free, demand-driven personal news intelligence platform powered by **NVIDIA Nemotron-3**, **Nebius Token Factory**, and **Tavily's 5-Endpoint Web Suite**.*

[![Live Demo](https://img.shields.io/badge/Live_Demo-Launch_App-00E676?style=for-the-badge&logo=googlechrome&logoColor=white)]([LIVE_DEMO_URL])
[![Pitch Video](https://img.shields.io/badge/Video_Pitch-Watch_on_YouTube-FF0000?style=for-the-badge&logo=youtube&logoColor=white)]([YOUTUBE_VIDEO_URL])
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge)](LICENSE)
[![Track](https://img.shields.io/badge/Track-Best_Apps_&_Agents-76B900?style=for-the-badge&logo=nvidia&logoColor=white)](#)

</div>

---

## 1. Why We Built WeOwnFeed

Modern news consumption is broken in three fundamental ways:
1. **Algorithmic Rage-Bait vs. Brittle RSS:** Social feeds optimize for outrage rather than user intent, while traditional RSS readers lock you into tracking specific blogs rather than **topics, entities, and questions you actually care about**.
2. **The Illusion of Consensus (Wire Syndication):** When 7 outlets republish the exact same Reuters or AP wire dispatch, naive AI aggregators treat them as "7 independent confirmations."
3. **Hallucinated Summaries & Zero Provenance:** Standard LLM news wrappers summarize articles without verifying claims against primary sources—and frequently fabricate or distort quotes.

**WeOwnFeed (WOF)** fixes this. Instead of subscribing to blogs, users build a personal feed from **7 core categories, 66 subtopics, custom `"+"` entity follows** (companies, products, people), **"RSS-less" websites**, and a natural-language **"Why I read news"** intent statement. Every clustered story comes with **Receipts**—an epistemic verification engine that strips wire duplicates, probes claims from three angles via Tavily, and enforces strict verbatim quote grounding.

---

## 2. Key Technical Differentiators

* **Verbatim Span Grounding (`span_is_grounded`):** LLMs never get the final word on quotes. Every extracted evidence quote must appear **verbatim** inside the raw text retrieved by Tavily Extract; otherwise, it is deterministically dropped (`server/evidence_verifier.py`)[cite: 1, 3]. Zero invented quotes[cite: 3].
* **Wire Syndication & Independent Origin Graph (`assign_origins`):** Using wire agency signatures (Reuters, AP, Bloomberg, PR Newswire) and shingle overlap detection, WOF collapses syndicated copies into a **single origin** (`server/evidence_verifier.py`)[cite: 1, 3]. Seven reposts of one wire story count as `1 origin`, preventing false multi-source confirmation[cite: 1, 3].
* **The Fresh News Rule (`unverified_yet`):** Breaking single-origin stories under 6 hours old are never falsely penalized as "contradicted" or "fake" before other newsrooms can report[cite: 1, 3]. Our rule-based verdict engine labels them `unverified_yet` and schedules re-verification[cite: 1, 3].
* **Demand-Driven Ingestion & Credit Protection (`query_scheduler.py`):** WOF only searches the web for topics actively followed by users, applying dynamic cadences (`6h` category, `24h` core, `48h` specific), low-yield exponential backoff, automatic multi-key rotation (`TAVILY_API_KEYS`), and a hard `TAVILY_CREDIT_RESERVE` floor so live verification never starves[cite: 2, 3].
* **3-Way Hybrid RRF Search & EMA Vector Personalization:** Combines `Qwen3-Embedding-8B` (1024-d) semantic similarity in PostgreSQL `pgvector`, full-text `websearch_to_tsquery`, and taxonomy tag matches via **Reciprocal Rank Fusion (RRF)**[cite: 1, 2, 3]. User likes move their personal interest vector **+15%** toward the story; dislikes push it **-12%** away via Exponential Moving Average (`ema_update`)[cite: 1, 3].

---

## 3. How We Used NVIDIA Open Models & Nebius Token Factory

> *Hackathon Mandatory Disclosure: How we leveraged NVIDIA Nemotron models, where Nebius Token Factory accelerated our engineering workflow, and our exact Nebius service footprint.*

### A. NVIDIA Nemotron-3 Models at the Core of Our Pipeline
All inference runs through a single unified OpenAI-compatible client (`server/ai.py`) pointed at **Nebius Token Factory** (`https://api.tokenfactory.nebius.com/v1/`)[cite: 1, 2, 3]. We architected a two-tier **NVIDIA Nemotron-3** pipeline matched to the latency and reasoning demands of each stage (full flow mapped in [`ai/MODEL_ORCHESTRATION.txt`](ai/MODEL_ORCHESTRATION.txt))[cite: 1, 3]:

1. **High-Throughput Enrichment Tier — `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B` (`SUMMARY_MODEL` & `TAG_MODEL`):**
   * Runs inside our parallel background worker (`ENRICHMENT_ENGINE=nano`, `NANO_CONCURRENCY=4`)[cite: 1, 2, 3].
   * **Non-Thinking Mode (`SUMMARY_MODEL`):** Generates tight 2-sentence (`<= 45 words`) news summaries and structured briefings (*Key Takeaways* + *Context & Significance*)[cite: 3].
   * **Thinking + Constrained JSON Schema Mode (`TAG_MODEL`):** Uses reasoning tokens combined with strict JSON schema enforcement to classify every story across our 7 categories and 66 subtopics[cite: 3].
2. **Deep Epistemic & Synthesis Tier — `nvidia/nemotron-3-super-120b-a12b` (`REASONING_MODEL`):**
   * Powers multi-source synthesis (`POST /api/intelligence/synthesize`), personalized Daily Digests (`GET /api/intelligence/daily-digest`), and streaming deep-dive Article Chat (`POST /api/articles/{id}/chat`) over verified evidence cards[cite: 1, 2, 3].

#### Full Model Orchestration Matrix (`server/ai.py` via Nebius Token Factory)

| Pipeline Role | Env Variable | Default Nebius Token Factory Model | Why This Model & Execution Mode |
| :--- | :--- | :--- | :--- |
| **Article Summary & Briefing** | `SUMMARY_MODEL` | **`nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B`** | Fast MoE inference (non-thinking) for strict `<=45 word` 2-sentence summaries and structured briefings[cite: 1, 3]. |
| **Taxonomy Classification** | `TAG_MODEL` | **`nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B`** | Thinking mode + strict JSON schema over 7 categories & 66 subtopics[cite: 1, 3]. |
| **Deep Synthesis & Digest** | `REASONING_MODEL` | **`nvidia/nemotron-3-super-120b-a12b`** | Heavy multi-document reasoning for cross-source synthesis, daily digests, and streaming article analysis[cite: 1, 2, 3]. |
| **Topic Gate & Claim Queries** | `FAST_MODEL` | `Qwen/Qwen3-30B-A3B-Instruct-2507` | Non-thinking Instruct model required for tight `max_tokens=30` gates (`{"on_topic": bool}`), atomic claim extraction, and fallbacks[cite: 1, 2, 3]. |
| **Multilingual Embeddings** | `EMBEDDING_MODEL` | `Qwen/Qwen3-Embedding-8B` (1024-d) | Cross-lingual subtopic matching, story clustering, and RRF hybrid search[cite: 1, 2, 3]. |
| **WAI News Assistant & Cards** | `WAI_MODEL` / `LATEST_MODEL` | `deepseek-ai/DeepSeek-V4-Flash-0731` | Low-latency SSE streaming for scoped WAI chats (`story` / `latest` / `area`) and home summary cards[cite: 1, 3]. |

*(Optional offline/hybrid fallbacks: Setting `ENRICHMENT_ENGINE=hybrid` activates local `convaiinnovations/laya` SLM triage in `server/classifier.py`, and `EMBEDDING_BACKEND=local` switches to 384-d `all-MiniLM-L6-v2`[cite: 1, 2, 3].)*

### B. Where Nebius Token Factory Accelerated Our Workflow
1. **Zero-Infrastructure Multi-Model Routing:** Instead of provisioning separate GPU nodes for a 30B MoE classifier, a 120B reasoning engine, and an 8B embedding model, Nebius Token Factory let us route 7 distinct specialized roles through **one API key and one OpenAI-compatible client (`server/ai.py`)**[cite: 1, 2, 3].
2. **Rapid Empirical Benchmarking (384-d Local vs. 1024-d Nebius Embeddings):** When our early prototype struggled with non-English (specifically Turkish) subtopic retrieval using local `all-MiniLM-L6-v2` (384 dims), we used Nebius Token Factory to benchmark `Qwen/Qwen3-Embedding-8B` (1024 dims) across **219 human-labeled articles** (`server/embedder.py`). Because Token Factory handled batch embedding throughput effortlessly, we validated and migrated our entire `pgvector` schema (`migrate_embeddings.py --rebuild`) in hours:

| Embedding Model & Backend | Vector Dims | Overall AUC (219 Articles) | Overall Precision@5 | Multilingual (TR) AUC | Multilingual (TR) Precision@5 |
| :--- | :---: | :---: | :---: | :---: | :---: |
| `all-MiniLM-L6-v2` (Local) | 384 | 0.903 | 0.56 | 0.598 | 0.18 |
| `Qwen3-Embedding-8B` (No Instruction) | 1024 | 0.917 | 0.53 | — | — |
| **`Qwen/Qwen3-Embedding-8B` (Nebius + Retrieval Instruction)** | **1024** | **0.940** | **0.64** | **0.935** | **0.59** |

3. **Real-World Discovery on Thinking vs. Non-Thinking Token Budgets:** High-concurrency testing on Token Factory revealed that calling reasoning/thinking models with small completion budgets (`max_tokens=30`) for binary JSON topic gates caused empty outputs because the token budget was consumed inside `<think>` blocks. Token Factory's model catalog let us immediately pair `NVIDIA-Nemotron-3-Nano-30B-A3B` (for summarization and schema-guided tagging) with `Qwen3-30B-A3B-Instruct-2507` (non-thinking) for ultra-low-token gates and automatic fallback chains[cite: 1, 2, 3].

### C. Scope of Nebius Tools & Services Used
In the spirit of engineering transparency: **100% of our cloud AI inference and embedding workloads run on Nebius Token Factory** (`https://api.tokenfactory.nebius.com/v1/`)[cite: 2, 3]. We did not need to provision standalone Nebius AI Cloud VMs, Serverless Jobs, or DevPods because Token Factory's managed OpenAI-compatible endpoints allowed our lightweight FastAPI + PostgreSQL (`pgvector`) containers to stay stateless and portable.

---

## 4. Deep Tavily Integration: All 5 Endpoints in Production

### From a Brittle 1,480-Line Scraper to Tavily's Unified Web Suite
Our V0 prototype (`server/legacy/scraping_algorithm.py`, preserved in the repo for reference) was a 1,480-line custom scraper stitching together DuckDuckGo, Yahoo RSS, Reddit, and Hacker News. In production testing, Cloudflare anti-bot blocks, paywalls, and brittle DOM selectors caused **>60% data loss**. We replaced the entire scraping stack with **all 5 endpoints of the Tavily API** (`server/tavily_service.py`)[cite: 1, 3]:

| Tavily Endpoint | Where It Runs in WeOwnFeed | Specific Engineering Purpose |
| :--- | :--- | :--- |
| **`1. Search`** | `ingest_tavily.py`, `evidence_verifier.py`, `routers/search.py` | **(a)** Demand-driven news ingestion (`topic=news`), **(b)** Live web horizon tier (`?live_web=true`) in hybrid search, and **(c)** Parallel **3-angle claim verification** (*support* query, *contradiction/denied* probe, and *official primary source* query using `include_domains`)[cite: 1, 3]. |
| **`2. Extract`** | `ingest_tavily.py`, `evidence_verifier.py`, `site_watcher.py` | Full-text recovery when search snippets are truncated/paywalled, plus fetching raw text from the top 5 verification URLs (1 official + 2 support + 2 contradiction) for `span_is_grounded()` verbatim quote checking[cite: 1, 3]. |
| **`3. Map`** | `site_watcher.py` (*RSS-less Newsroom Watcher*) | Maps URL trees of corporate newsrooms and research labs that **do not offer RSS feeds**[cite: 1, 3]. Computes URL diffs against PostgreSQL to detect newly published articles automatically[cite: 1, 3]. |
| **`4. Crawl`** | `site_watcher.py` | Performs targeted crawls on newly discovered editorial paths surfaced by Tavily Map[cite: 1, 3]. |
| **`5. Research`** | `routers/intelligence.py` (`POST /api/articles/{id}/deep-inspect/research`) | On-demand autonomous multi-search research briefing when a user triggers **Deep Inspect** on a complex or disputed story[cite: 1, 3]. |

**Built-in Telemetry & Cost Control:** Every Tavily call is logged to our `tavily_calls` table and exposed via `GET /api/tavily/stats` and `GET /api/tavily/calls`—tracking endpoint distribution, purpose breakdown, latency (ms), credit spend, cache hits, and automatic multi-key failover (`TAVILY_API_KEYS`)[cite: 1, 2, 3].

---

## 5. System Architecture & Pipelines

```text
+-----------------------------------------------------------------------------------+
|                        1. DEMAND-DRIVEN INGESTION & WATCHER                       |
|  User Follows (Topics, "+", Sites) -> query_scheduler.py (Cadence & Credit Guard) |
|    ├── ingest_tavily.py : Tavily Search (topic=news) --[short]--> Tavily Extract  |
|    └── site_watcher.py  : Tavily Map (URL Diff vs DB) ----------> Tavily Crawl    |
|                                        │                                          |
|                                        ▼                                          |
|           content_cleaner.py (4-pass Markdown cleaner, shingle de-dup)            |
+-----------------------------------------------------------------------------------+
                                         │
                                         ▼
+-----------------------------------------------------------------------------------+
|            2. NEBIUS TOKEN FACTORY ENRICHMENT WORKER (NANO_CONCURRENCY=4)         |
|  [1] SUMMARY   : nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B (2 sentences, <=45 words)  |
|  [2] TOPIC GATE: Qwen/Qwen3-30B-A3B-Instruct-2507 ({"on_topic": true|false})      |
|  [3] TAXONOMY  : nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B (Thinking + JSON Schema)   |
|  [4] BRIEFING  : nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B (Takeaways + Context)      |
|  [5] EMBEDDING : Qwen/Qwen3-Embedding-8B (1024-d vector stored in pgvector)       |
|  [6] CLUSTERING: Cosine match + assign_origins() wire syndication collapse        |
+-----------------------------------------------------------------------------------+
                                         │
                                         ▼
+-----------------------------------------------------------------------------------+
|                 3. EPISTEMIC "RECEIPTS" ENGINE (evidence_verifier.py)             |
|  Story Cluster -> assign_origins() (<6h single-origin = Fresh News Guard)         |
|    └── Extract 2-3 Atomic Claims (FAST_MODEL)                                     |
|          ├── Tavily Search #1: Neutral Support                                    |
|          ├── Tavily Search #2: Contradiction / Denial Probe                       |
|          └── Tavily Search #3: Official Domain (include_domains)                  |
|                └── Pick 5 URLs -> Tavily Extract -> span_is_grounded()            |
|                      └── Rule-Based Verdict: supported | disputed | contradicted  |
|                          | unverified_yet (fresh <6h) | unverified                |
+-----------------------------------------------------------------------------------+
                                         │
                                         ▼
+-----------------------------------------------------------------------------------+
|                     4. USER EXPERIENCE (Flutter Web & Mobile App)                 |
|  • Personalized Feed (EMA vector updates: +15% like / -12% dislike)               |
|  • 3-Way Hybrid RRF Search + Live Web Horizon (?live_web=true)                    |
|  • Deep Synthesis & Daily Digest powered by nvidia/nemotron-3-super-120b-a12b     |
|  • Scoped WAI Streaming Assistant & On-Demand Tavily Research Deep Inspect        |
+-----------------------------------------------------------------------------------+
