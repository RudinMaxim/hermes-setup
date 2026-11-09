#!/usr/bin/env python3
"""Daily integration health check for a Hermes host. No LLM, stdlib only.

Checks that every connection the agent depends on still authenticates, and messages the owner in
VK when one breaks (and once more when it recovers), so an expired token never surfaces first as
"календарь недоступен" inside the morning briefing.

Checks:
  google   — refresh the OAuth token in ~/.hermes/google_token.json (not written back)
             + warns when the refresh token nears Google's 7-day limit for apps in "Testing"
  todoist  — Todoist API with MCP_TODOIST_API_KEY
  vk       — groups.getById with VK_GROUP_TOKEN
  timeweb  — 1-token completion on the main model (catches a bad key AND an empty balance)
  regcloud — /models with REGCLOUD_API_KEY (fallback provider)

Usage: integrations-check.py [--dry-run] [--force-notify]
  --dry-run       print results, send nothing, keep state untouched
  --force-notify  send the summary to VK even if nothing changed (to test delivery)

Env (from ~/.hermes/.env): VK_GROUP_TOKEN, VK_HOME_CHANNEL (owner peer id), MCP_TODOIST_API_KEY,
TIMEWEB_API_KEY, REGCLOUD_API_KEY. Optional: HC_GOOGLE_MODE=testing|production (default testing),
HC_TIMEWEB_MODEL (default anthropic/claude-haiku-5-5). Secrets are never printed.
"""
import hashlib
import json
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

HOME = Path(os.environ.get("HERMES_HOME", Path.home() / ".hermes"))
STATE = HOME / "integrations-check.json"
TIMEOUT = 25


def load_env():
    env = {}
    p = HOME / ".env"
    if p.exists():
        for line in p.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip().strip('"').strip("'")
    env.update({k: v for k, v in os.environ.items() if k.startswith(("HC_", "VK_", "TIMEWEB_", "REGCLOUD_", "MCP_"))})
    return env


def http(method, url, headers=None, data=None):
    body = None
    if data is not None:
        body = json.dumps(data).encode() if isinstance(data, (dict, list)) else data
    req = urllib.request.Request(url, data=body, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # network error, timeout
        return 0, f"{type(e).__name__}: {e}"


def short(text, n=160):
    return " ".join(str(text).split())[:n]


# --- checks: each returns (ok: bool, detail: str, fix: str) -------------------------------------

def check_google(env, state):
    p = HOME / "google_token.json"
    if not p.exists():
        return False, "нет google_token.json", "Подключить Google заново (авторизация в браузере)."
    t = json.loads(p.read_text(encoding="utf-8"))
    form = urllib.parse.urlencode({
        "client_id": t.get("client_id", ""), "client_secret": t.get("client_secret", ""),
        "refresh_token": t.get("refresh_token", ""), "grant_type": "refresh_token",
    }).encode()
    code, body = http("POST", t.get("token_uri", "https://oauth2.googleapis.com/token"),
                      {"Content-Type": "application/x-www-form-urlencoded"}, form)
    fix = ("Переподключить Google: авторизация заново в браузере. Чтобы токен не умирал каждые 7 дней — "
           "перевести OAuth consent screen в Google Cloud в «In production».")
    if code != 200:
        err = short(body)
        try:
            j = json.loads(body)
            err = f"{j.get('error')}: {j.get('error_description', '')}"
        except ValueError:
            pass
        return False, f"обновление токена не прошло ({code}) {err}", fix
    # Age of the refresh token: Google's "Testing" apps expire it after 7 days.
    fp = hashlib.sha256(t.get("refresh_token", "").encode()).hexdigest()[:16]
    g = state.setdefault("google", {})
    if g.get("fp") != fp:
        g["fp"], g["first_seen"] = fp, time.time()
    age_days = (time.time() - g["first_seen"]) / 86400
    if env.get("HC_GOOGLE_MODE", "testing") == "testing" and age_days >= 5.5:
        return True, f"работает, но токену {age_days:.1f} дн. — в режиме Testing Google отзовёт его на 7-й день", fix
    return True, "токен обновляется", ""


def check_todoist(env, state):
    key = env.get("MCP_TODOIST_API_KEY")
    if not key:
        return False, "нет MCP_TODOIST_API_KEY", "Добавить API-ключ Todoist в ~/.hermes/.env."
    code, body = http("GET", "https://api.todoist.com/api/v1/projects?limit=1", {"Authorization": f"Bearer {key}"})
    if code == 200:
        return True, "API отвечает", ""
    return False, f"API вернул {code} {short(body, 100)}", ("Ключ Todoist отозван или сменён: Todoist → Настройки → "
                                                          "Интеграции → Для разработчиков → скопировать ключ в .env.")


def check_vk(env, state):
    tok = env.get("VK_GROUP_TOKEN")
    if not tok:
        return False, "нет VK_GROUP_TOKEN", "Добавить ключ сообщества VK в .env."
    q = urllib.parse.urlencode({"access_token": tok, "v": "5.199"})
    code, body = http("GET", f"https://api.vk.com/method/groups.getById?{q}")
    try:
        j = json.loads(body)
    except ValueError:
        j = {}
    if code == 200 and "response" in j:
        return True, "ключ сообщества действует", ""
    err = j.get("error", {})
    return False, f"VK: {err.get('error_code', code)} {short(err.get('error_msg', body), 100)}", (
        "Ключ сообщества VK недействителен: Управление сообществом → Работа с API → создать ключ, обновить .env.")


def check_timeweb(env, state):
    key = env.get("TIMEWEB_API_KEY")
    if not key:
        return False, "нет TIMEWEB_API_KEY", "Добавить ключ Timeweb AI в .env."
    model = env.get("HC_TIMEWEB_MODEL", "anthropic/claude-haiku-5-5")
    code, body = http("POST", "https://api.timeweb.ai/v1/chat/completions",
                      {"Authorization": f"Bearer {key}", "Content-Type": "application/json"},
                      {"model": model, "max_tokens": 1, "messages": [{"role": "user", "content": "ok"}]})
    if code == 200:
        return True, f"модель {model} отвечает", ""
    hint = "Пополнить баланс Timeweb AI." if code in (402, 403) or "balance" in body.lower() else (
        "Проверить ключ и баланс в кабинете Timeweb AI.")
    return False, f"Timeweb {code} {short(body, 120)}", hint


def check_regcloud(env, state):
    key = env.get("REGCLOUD_API_KEY")
    if not key:
        return True, "не настроен (пропуск)", ""
    code, body = http("GET", "https://ai.reg.cloud/v1/models", {"Authorization": f"Bearer {key}"})
    if code == 200:
        return True, "ключ действует", ""
    return False, f"reg.cloud {code} {short(body, 100)}", "Запасной провайдер недоступен: проверить ключ и баланс reg.cloud."


CHECKS = [("google", "Google (Календарь, Почта)", check_google), ("todoist", "Todoist", check_todoist),
          ("vk", "VK", check_vk), ("timeweb", "Timeweb AI (основная модель)", check_timeweb),
          ("regcloud", "reg.cloud (запасная модель)", check_regcloud)]


def send_vk(env, text):
    tok, peer = env.get("VK_GROUP_TOKEN"), env.get("VK_HOME_CHANNEL")
    if not tok or not peer:
        print("VK: нет VK_GROUP_TOKEN или VK_HOME_CHANNEL — уведомление не отправлено", file=sys.stderr)
        return False
    form = urllib.parse.urlencode({"access_token": tok, "v": "5.199", "peer_id": peer,
                                   "random_id": random.randint(1, 2**31 - 1), "message": text}).encode()
    code, body = http("POST", "https://api.vk.com/method/messages.send",
                      {"Content-Type": "application/x-www-form-urlencoded"}, form)
    ok = code == 200 and '"response"' in body
    if not ok:
        print(f"VK send failed: {code} {short(body, 120)}", file=sys.stderr)
    return ok


def main():
    dry, force = "--dry-run" in sys.argv, "--force-notify" in sys.argv
    env = load_env()
    state = json.loads(STATE.read_text()) if STATE.exists() else {}
    prev = state.get("status", {})
    results, changed = [], []
    for key, title, fn in CHECKS:
        try:
            ok, detail, fix = fn(env, state)
        except Exception as e:
            ok, detail, fix = False, f"проверка упала: {type(e).__name__}: {short(e, 100)}", ""
        warn = ok and bool(fix)  # works now, but will break soon
        level = "fail" if not ok else ("warn" if warn else "ok")
        results.append((key, title, level, detail, fix))
        print(f"[{level.upper():4}] {key}: {detail}")
        if prev.get(key) != level:
            changed.append(key)
        state.setdefault("status", {})[key] = level
    state["last_run"] = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime())

    bad = [r for r in results if r[2] != "ok"]
    recovered = [r for r in results if r[2] == "ok" and r[0] in changed and prev.get(r[0]) in ("fail", "warn")]
    notify = force or any(r[0] in changed for r in bad) or recovered
    if notify:
        lines = ["🔧 Проверка подключений агента"]
        for _, title, level, detail, fix in bad:
            lines.append(f"\n{'❌' if level == 'fail' else '⚠️'} {title}: {detail}")
            if fix:
                lines.append(f"Что сделать: {fix}")
        for _, title, *_ in recovered:
            lines.append(f"\n✅ {title}: снова работает")
        if not bad and not recovered:
            lines.append("\nВсё работает ✅")
        text = "\n".join(lines)
        if dry:
            print("--- would send to VK ---\n" + text)
        else:
            send_vk(env, text)
    if not dry:
        STATE.write_text(json.dumps(state, ensure_ascii=False, indent=1))
        os.chmod(STATE, 0o600)
    sys.exit(1 if any(r[2] == "fail" for r in results) else 0)


if __name__ == "__main__":
    main()
