import sys
import time
import os
import re

# Enable UTF-8 and ANSI escape sequences on Windows
sys.stdout.reconfigure(encoding="utf-8")
if os.name == "nt":
    os.system("")

# Styling Palette (Clean Developer Terminal Aesthetic)
RESET   = "\033[0m"
BOLD    = "\033[1m"
DIM     = "\033[2m"
RED     = "\033[91m"
GREEN   = "\033[92m"
YELLOW  = "\033[93m"
CYAN    = "\033[96m"
MAGENTA = "\033[95m"
GREY    = "\033[90m"
WHITE   = "\033[97m"

# Hide cursor during playback
sys.stdout.write("\033[?25l")
sys.stdout.flush()

def clear():
    os.system("cls" if os.name == "nt" else "clear")

def visible_len(s):
    # Strip ANSI escape sequences to compute true printable width
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    return len(ansi_escape.sub('', s))

def pad_visible(s, target_len):
    cur = visible_len(s)
    if cur < target_len:
        return s + " " * (target_len - cur)
    return s

def type_cmd(prompt, command, delay=0.02):
    sys.stdout.write(prompt)
    sys.stdout.flush()
    time.sleep(0.1)
    for ch in command:
        sys.stdout.write(ch)
        sys.stdout.flush()
        time.sleep(delay)
    sys.stdout.write("\n")
    sys.stdout.flush()
    time.sleep(0.08)

def print_line(text, delay=0.06):
    sys.stdout.write(text + "\n")
    sys.stdout.flush()
    time.sleep(delay)

try:
    clear()
    time.sleep(0.15)

    # =========================================================================
    # ACT 1: The Scraper Meltdown (The Brittle Past)
    # =========================================================================
    sys.stdout.write(f"{GREY}talha@nebius-workstation:~/rss-backend$ {WHITE}python legacy/scraping_algorithm.py{RESET}\n")
    sys.stdout.flush()
    time.sleep(0.25)

    print_line(f"{RED}[ERROR] scraper.network: HTTP 429 Too Many Requests | Cloudflare Turnstile lock{RESET}", 0.08)
    print_line(f"{GREY}Traceback (most recent call last):\n  File \"legacy/scraping_algorithm.py\", line 1248, in extract_body\n    article_text = soup.find('div', class_='article-body').text{RESET}", 0.05)
    print_line(f"{RED}AttributeError: 'NoneType' object has no attribute 'text'{RESET}", 0.08)
    print_line(f"{RED}[CRITICAL] Yield collapse: 62.4% failure rate across 1,482 lines of brittle scrapers.{RESET}", 0.12)
    print_line(f"{YELLOW}^C  Terminating zombie scraper workers... Deprecated to legacy/{RESET}\n", 0.25)

    # =========================================================================
    # ACT 2: System Architecture Spec Grid (The Sponsors & Engine)
    # =========================================================================
    type_cmd(f"{GREY}talha@nebius-workstation:~/rss-backend$ {WHITE}", "python main.py --engine autonomous", delay=0.018)
    time.sleep(0.1)

    w_left = 36
    w_right = 36
    w_total = w_left + 1 + w_right  # 73 visible characters wide

    bc = CYAN  # Border color

    top     = f"{bc}┌{'─' * w_total}┐{RESET}"
    l1_text = f"  {BOLD}{WHITE}FEEDPROOF // AUTONOMOUS NEWS INTELLIGENCE ENGINE{RESET}"
    l1      = f"{bc}│{RESET}{pad_visible(l1_text, w_total)}{bc}│{RESET}"
    l2_text = f"  {GREY}Stack: Python 3.11 · FastAPI · PyTorch · PostgreSQL 16 (pgvector){RESET}"
    l2      = f"{bc}│{RESET}{pad_visible(l2_text, w_total)}{bc}│{RESET}"
    mid_sep = f"{bc}├{'─' * w_left}┬{'─' * w_right}┤{RESET}"

    r1_l = pad_visible(f"  {WHITE}Inference:{RESET} {MAGENTA}Nebius Token Factory{RESET}", w_left)
    r1_r = pad_visible(f"  {WHITE}Web Mesh:{RESET} {CYAN}Tavily 5-Endpoint API{RESET}", w_right)
    r1   = f"{bc}│{RESET}{r1_l}{bc}│{RESET}{r1_r}{bc}│{RESET}"

    r2_l = pad_visible(f"  {WHITE}Models:{RESET}    {BOLD}NVIDIA Nemotron 70B{RESET}", w_left)
    r2_r = pad_visible(f"  {WHITE}Triage:{RESET}   {GREEN}Laya SLM (<80ms edge){RESET}", w_right)
    r2   = f"{bc}│{RESET}{r2_l}{bc}│{RESET}{r2_r}{bc}│{RESET}"

    r3_l = pad_visible(f"  {WHITE}Vectors:{RESET}   {BOLD}pgvector HNSW (384d){RESET}", w_left)
    r3_r = pad_visible(f"  {WHITE}Receipts:{RESET} {YELLOW}Span Grounded + Wire{RESET}", w_right)
    r3   = f"{bc}│{RESET}{r3_l}{bc}│{RESET}{r3_r}{bc}│{RESET}"

    bot = f"{bc}└{'─' * w_left}┴{'─' * w_right}┘{RESET}"

    grid = f"{top}\n{l1}\n{l2}\n{mid_sep}\n{r1}\n{r2}\n{r3}\n{bot}"
    print_line(grid, 0.12)

    # Subsystem checklist
    print_line(f" {GREEN}[OK]{RESET} {BOLD}PostgreSQL 16 + pgvector:{RESET} HNSW index online {DIM}(cosine distance < 0.42){RESET}", 0.07)
    print_line(f" {GREEN}[OK]{RESET} {BOLD}Tavily 5-Endpoint Mesh:{RESET}   search · extract · map · crawl · research ... {GREEN}CONNECTED{RESET}", 0.07)
    print_line(f" {GREEN}[OK]{RESET} {BOLD}Edge SLM Triage:{RESET}          convaiinnovations/laya loaded on {MAGENTA}cuda:0{RESET} ({GREEN}<80ms latency{RESET})", 0.07)
    print_line(f" {GREEN}[OK]{RESET} {BOLD}Nebius Token Factory:{RESET}     NVIDIA Nemotron 70B & Llama 3.1 8B Instruct ... {GREEN}ARMED{RESET}", 0.07)
    print_line(f" {GREEN}[OK]{RESET} {BOLD}Verifiable Receipts:{RESET}      Span-grounding & Reuters wire deduplication ... {GREEN}ENABLED{RESET}", 0.07)
    print_line(f" {GREEN}[OK]{RESET} {BOLD}Test Suite Regression:{RESET}    27 API Routes · 90/90 Master Evaluation {BOLD}{GREEN}(100.0% A+){RESET}\n", 0.12)

    # =========================================================================
    # ACT 3: Live Ingestion Pipeline & Web Client Connection
    # =========================================================================
    print_line(f"{GREY}--- [LIVE NEWSROOM PIPELINE: ACTIVE INGESTION CYCLE #142] ----------------{RESET}", 0.08)
    
    ts = time.strftime("%H:%M:%S")
    print_line(f"{GREY}[{ts}]{RESET} {CYAN}[TAVILY-MAP]{RESET}    Discovered +1 URL tree diff: {BOLD}reuters.com/technology/quantum-leap{RESET}", 0.08)
    print_line(f"{GREY}[{ts}]{RESET} {CYAN}[CLEANER-4P]{RESET}   Sanitized raw Markdown: stripped 14 inline promo banners (18.4KB -> 4.1KB)", 0.08)
    print_line(f"{GREY}[{ts}]{RESET} {GREEN}[LAYA-SLM]{RESET}     Triaged in {BOLD}{GREEN}42ms{RESET}: Macro=[{BOLD}Tech{RESET}] · Micro=[{CYAN}quantum, 10000-qubit, ibm{RESET}]", 0.09)
    print_line(f"{GREY}[{ts}]{RESET} {MAGENTA}[PGVECTOR]{RESET}     Dense 384d embedding indexed via HNSW (<11ms)", 0.07)
    print_line(f"{GREY}[{ts}]{RESET} {MAGENTA}[NEMOTRON]{RESET}    Generated empirical 2-sentence TL;DR + wire origin deduplicated", 0.08)
    print_line(f"{GREY}[{ts}]{RESET} {YELLOW}[RECEIPTS]{RESET}     Verbatim quote span verified against Tavily raw extract (100% grounded)", 0.08)
    
    time.sleep(0.12)
    print_line(f"\n{GREEN}{BOLD}>> GATEWAY 127.0.0.1:8000 ONLINE.{RESET} Client 127.0.0.1:5173 connected.", 0.08)
    print_line(f"{GREEN}INFO:{RESET}     127.0.0.1:5173 - \"{BOLD}GET /api/feed/personalized?user=hackathon_judge{RESET}\" {GREEN}{BOLD}200 OK (34ms){RESET}", 0.05)
    print_line(f"{CYAN}STREAM:{RESET}   Pushing real-time SSE intelligence payload to WeOwnFeed frontend...\n", 0.8)

finally:
    # Restore terminal cursor
    sys.stdout.write("\033[?25h")
    sys.stdout.flush()