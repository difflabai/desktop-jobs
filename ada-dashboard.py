#!/usr/bin/env python3
"""ada dashboard — lightweight web UI for ATS tasks + ada service status + log tails."""

import glob
import http.server
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request

ATS_URL = os.environ.get("ATS_URL", "https://ats.difflab.ai")
ADA_HOME = os.path.expanduser("~/.ada")
SERVICES_JSON = os.path.join(os.path.dirname(os.path.abspath(__file__)), "services.json")
LOG_DIRS = [os.path.join(ADA_HOME, "logs"), "/tmp"]
LOG_TAIL_LINES = 80
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7070


def get_services():
    """Read ada services and their live status."""
    try:
        with open(SERVICES_JSON) as f:
            services = json.load(f)
    except Exception:
        return []

    result = []
    for svc in services:
        name = svc.get("name", "")
        pid_file = os.path.join(ADA_HOME, "pids", f"{name}.pid")
        state_file = os.path.join(ADA_HOME, "state", f"{name}.json")
        log_file = os.path.join(ADA_HOME, "logs", f"{name}.log")

        pid = None
        running = False
        if os.path.isfile(pid_file):
            try:
                pid = int(open(pid_file).read().strip())
                os.kill(pid, 0)
                running = True
            except (ValueError, ProcessLookupError, PermissionError):
                pid = None

        state = {}
        if os.path.isfile(state_file):
            try:
                state = json.load(open(state_file))
            except Exception:
                pass

        uptime = None
        started_at = state.get("started_at")
        if running and started_at:
            import time
            uptime = int(time.time()) - int(started_at)

        status = "running" if running else ("disabled" if not svc.get("enabled", True) else "stopped")
        if state.get("crash_loop"):
            status = "crash-loop"

        result.append({
            "name": name,
            "enabled": svc.get("enabled", True),
            "pid": pid,
            "status": status,
            "uptime": uptime,
            "restart_count": state.get("restart_count", 0),
            "has_log": os.path.isfile(log_file),
        })
    return result


def get_ats_tasks(limit=50, status=None):
    """Fetch tasks from ATS API."""
    params = {"limit": str(limit)}
    if status:
        params["status"] = status
    url = f"{ATS_URL}/tasks?{urllib.parse.urlencode(params)}"
    try:
        req = urllib.request.Request(url, headers={"Accept": "application/json"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            return json.loads(resp.read())
    except Exception as e:
        return {"error": str(e), "tasks": []}


def get_log_files():
    """List available log files from /tmp and ~/.ada/logs."""
    logs = []
    for d in LOG_DIRS:
        for path in sorted(glob.glob(os.path.join(d, "*.log"))):
            try:
                stat = os.stat(path)
                logs.append({
                    "path": path,
                    "name": os.path.basename(path),
                    "dir": d,
                    "size": stat.st_size,
                    "mtime": stat.st_mtime,
                })
            except OSError:
                pass
    logs.sort(key=lambda x: x["mtime"], reverse=True)
    return logs


def tail_file(path, lines=LOG_TAIL_LINES):
    """Return last N lines of a file."""
    try:
        result = subprocess.run(
            ["tail", "-n", str(lines), path],
            capture_output=True, text=True, timeout=3
        )
        return result.stdout
    except Exception as e:
        return f"Error reading log: {e}"


DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Ada Dashboard</title>
<style>
  :root {
    --bg: #0d1117; --surface: #161b22; --border: #30363d;
    --text: #c9d1d9; --text-dim: #8b949e; --text-bright: #f0f6fc;
    --green: #3fb950; --yellow: #d29922; --red: #f85149;
    --blue: #58a6ff; --cyan: #39d2e0; --purple: #bc8cff;
  }
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Helvetica, Arial, sans-serif;
    background: var(--bg); color: var(--text); line-height: 1.5;
  }
  header {
    background: var(--surface); border-bottom: 1px solid var(--border);
    padding: 12px 24px; display: flex; align-items: center; gap: 16px;
    position: sticky; top: 0; z-index: 100;
  }
  header h1 { font-size: 18px; color: var(--text-bright); font-weight: 600; }
  header .meta { color: var(--text-dim); font-size: 13px; margin-left: auto; }
  .refresh-dot {
    display: inline-block; width: 8px; height: 8px; border-radius: 50%;
    background: var(--green); margin-right: 6px; transition: opacity 0.3s;
  }
  .refresh-dot.fetching { animation: pulse 0.6s ease-in-out infinite; }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.3; } }

  .container { max-width: 1400px; margin: 0 auto; padding: 20px 24px; }
  .grid { display: grid; grid-template-columns: 1fr 1fr; gap: 20px; }
  @media (max-width: 900px) { .grid { grid-template-columns: 1fr; } }

  .panel {
    background: var(--surface); border: 1px solid var(--border);
    border-radius: 8px; overflow: hidden;
  }
  .panel-header {
    padding: 12px 16px; border-bottom: 1px solid var(--border);
    display: flex; align-items: center; gap: 10px;
  }
  .panel-header h2 { font-size: 14px; font-weight: 600; color: var(--text-bright); }
  .panel-header .count {
    background: var(--border); border-radius: 10px; padding: 1px 8px;
    font-size: 12px; color: var(--text-dim);
  }
  .panel-body { padding: 0; }

  /* Services */
  .svc-row {
    display: grid; grid-template-columns: 20px 1fr 60px 80px 50px;
    gap: 8px; padding: 8px 16px; border-bottom: 1px solid var(--border);
    align-items: center; font-size: 13px;
  }
  .svc-row:last-child { border-bottom: none; }
  .dot { width: 10px; height: 10px; border-radius: 50%; }
  .dot.running { background: var(--green); }
  .dot.stopped { background: var(--yellow); }
  .dot.disabled { background: var(--text-dim); opacity: 0.4; }
  .dot.crash-loop { background: var(--red); animation: pulse 1s infinite; }
  .svc-name { color: var(--text-bright); font-weight: 500; }
  .svc-pid { color: var(--text-dim); font-family: monospace; font-size: 12px; }
  .svc-uptime { color: var(--text-dim); font-size: 12px; }
  .svc-restarts { font-size: 12px; text-align: right; }

  /* Tasks */
  .task-filters {
    padding: 8px 16px; border-bottom: 1px solid var(--border);
    display: flex; gap: 6px; flex-wrap: wrap;
  }
  .filter-btn {
    padding: 3px 10px; border-radius: 12px; border: 1px solid var(--border);
    background: transparent; color: var(--text-dim); cursor: pointer;
    font-size: 12px; transition: all 0.15s;
  }
  .filter-btn:hover { border-color: var(--text-dim); }
  .filter-btn.active { background: var(--blue); color: var(--bg); border-color: var(--blue); }

  .task-list { max-height: 420px; overflow-y: auto; }
  .task-row {
    padding: 10px 16px; border-bottom: 1px solid var(--border);
    display: flex; align-items: flex-start; gap: 10px; font-size: 13px;
  }
  .task-row:last-child { border-bottom: none; }
  .task-id { color: var(--text-dim); font-family: monospace; min-width: 36px; font-size: 12px; }
  .task-title { color: var(--text-bright); flex: 1; }
  .task-channel { color: var(--purple); font-size: 11px; }
  .badge {
    display: inline-block; padding: 1px 8px; border-radius: 10px;
    font-size: 11px; font-weight: 500; white-space: nowrap;
  }
  .badge.pending { background: #d2992233; color: var(--yellow); }
  .badge.in_progress { background: #58a6ff22; color: var(--blue); }
  .badge.completed { background: #3fb95022; color: var(--green); }
  .badge.failed { background: #f8514922; color: var(--red); }
  .badge.cancelled { background: #30363d; color: var(--text-dim); }

  /* Logs */
  .full-width { grid-column: 1 / -1; }
  .log-selector {
    padding: 8px 16px; border-bottom: 1px solid var(--border);
    display: flex; gap: 8px; align-items: center; flex-wrap: wrap;
  }
  .log-selector select {
    background: var(--bg); color: var(--text); border: 1px solid var(--border);
    border-radius: 4px; padding: 4px 8px; font-size: 13px;
  }
  .log-selector label { color: var(--text-dim); font-size: 12px; }
  .log-output {
    background: #010409; padding: 12px 16px; font-family: 'SFMono-Regular', Consolas, monospace;
    font-size: 12px; line-height: 1.6; overflow: auto; max-height: 500px;
    white-space: pre-wrap; word-break: break-all; color: var(--text);
  }
  .log-output .ts { color: var(--text-dim); }
  .empty { padding: 24px; text-align: center; color: var(--text-dim); font-size: 13px; }
</style>
</head>
<body>
<header>
  <h1>Ada Dashboard</h1>
  <span class="meta"><span class="refresh-dot" id="dot"></span>Refreshes every 5s</span>
</header>
<div class="container">
  <div class="grid">
    <!-- Services Panel -->
    <div class="panel">
      <div class="panel-header">
        <h2>Services</h2>
        <span class="count" id="svc-count">0</span>
      </div>
      <div class="panel-body" id="svc-body">
        <div class="empty">Loading...</div>
      </div>
    </div>

    <!-- Tasks Panel -->
    <div class="panel">
      <div class="panel-header">
        <h2>ATS Tasks</h2>
        <span class="count" id="task-count">0</span>
      </div>
      <div class="task-filters" id="task-filters">
        <button class="filter-btn active" data-status="">All</button>
        <button class="filter-btn" data-status="in_progress">In Progress</button>
        <button class="filter-btn" data-status="pending">Pending</button>
        <button class="filter-btn" data-status="completed">Completed</button>
        <button class="filter-btn" data-status="failed">Failed</button>
      </div>
      <div class="panel-body task-list" id="task-body">
        <div class="empty">Loading...</div>
      </div>
    </div>

    <!-- Logs Panel -->
    <div class="panel full-width">
      <div class="panel-header">
        <h2>Logs</h2>
      </div>
      <div class="log-selector">
        <label for="log-select">File:</label>
        <select id="log-select"><option value="">Select a log file...</option></select>
        <label><input type="checkbox" id="log-auto" checked> Auto-scroll</label>
      </div>
      <div class="panel-body">
        <div class="log-output" id="log-output">Select a log file above to view its tail.</div>
      </div>
    </div>
  </div>
</div>

<script>
const $ = s => document.querySelector(s);
let taskFilter = '';
let currentLog = '';

function humanDuration(secs) {
  if (!secs || secs < 0) return '-';
  if (secs < 60) return secs + 's';
  if (secs < 3600) return Math.floor(secs/60) + 'm ' + (secs%60) + 's';
  if (secs < 86400) return Math.floor(secs/3600) + 'h ' + Math.floor((secs%3600)/60) + 'm';
  return Math.floor(secs/86400) + 'd ' + Math.floor((secs%86400)/3600) + 'h';
}

function escapeHtml(s) {
  const d = document.createElement('div'); d.textContent = s; return d.innerHTML;
}

async function fetchJSON(url) {
  const r = await fetch(url);
  return r.json();
}

async function refreshServices() {
  try {
    const svcs = await fetchJSON('/api/services');
    const el = $('#svc-body');
    $('#svc-count').textContent = svcs.length;
    if (!svcs.length) { el.innerHTML = '<div class="empty">No services configured</div>'; return; }
    el.innerHTML = svcs.map(s => `
      <div class="svc-row">
        <span class="dot ${s.status}"></span>
        <span class="svc-name">${escapeHtml(s.name)}</span>
        <span class="svc-pid">${s.pid || '-'}</span>
        <span class="svc-uptime">${s.uptime != null ? humanDuration(s.uptime) : '-'}</span>
        <span class="svc-restarts" style="color:${s.restart_count > 5 ? 'var(--red)' : s.restart_count > 0 ? 'var(--yellow)' : 'var(--text-dim)'}">
          ↻${s.restart_count}
        </span>
      </div>`).join('');
  } catch(e) { console.error('services fetch failed', e); }
}

async function refreshTasks() {
  try {
    const params = taskFilter ? `?status=${taskFilter}` : '?limit=50';
    const data = await fetchJSON('/api/tasks' + params);
    const tasks = data.tasks || [];
    const el = $('#task-body');
    $('#task-count').textContent = tasks.length;
    if (!tasks.length) { el.innerHTML = '<div class="empty">No tasks</div>'; return; }
    el.innerHTML = tasks.map(t => `
      <div class="task-row">
        <span class="task-id">#${t.id}</span>
        <div>
          <div class="task-title">${escapeHtml(t.title)}</div>
          <span class="task-channel">${escapeHtml(t.channel || '')}</span>
        </div>
        <span class="badge ${t.status}">${t.status}</span>
      </div>`).join('');
  } catch(e) { console.error('tasks fetch failed', e); }
}

async function refreshLogs() {
  try {
    const logs = await fetchJSON('/api/logs');
    const sel = $('#log-select');
    const prev = sel.value;
    const opts = '<option value="">Select a log file...</option>' +
      logs.map(l => `<option value="${escapeHtml(l.path)}">${escapeHtml(l.name)} (${(l.size/1024).toFixed(0)}K)</option>`).join('');
    sel.innerHTML = opts;
    if (prev) sel.value = prev;
  } catch(e) { console.error('log list failed', e); }
}

async function refreshLogContent() {
  if (!currentLog) return;
  try {
    const data = await fetchJSON('/api/logs/tail?path=' + encodeURIComponent(currentLog));
    const el = $('#log-output');
    el.textContent = data.content || 'Empty log.';
    if ($('#log-auto').checked) el.scrollTop = el.scrollHeight;
  } catch(e) { console.error('log tail failed', e); }
}

// Filter buttons
$('#task-filters').addEventListener('click', e => {
  const btn = e.target.closest('.filter-btn');
  if (!btn) return;
  document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
  btn.classList.add('active');
  taskFilter = btn.dataset.status;
  refreshTasks();
});

// Log selector
$('#log-select').addEventListener('change', e => {
  currentLog = e.target.value;
  if (currentLog) refreshLogContent();
  else $('#log-output').textContent = 'Select a log file above to view its tail.';
});

// Main refresh loop
async function refresh() {
  const dot = $('#dot');
  dot.classList.add('fetching');
  await Promise.all([refreshServices(), refreshTasks(), refreshLogContent()]);
  dot.classList.remove('fetching');
}

// Initial load
refreshLogs();
refresh();

// Poll
setInterval(refresh, 5000);
setInterval(refreshLogs, 15000);
</script>
</body>
</html>
"""


class DashboardHandler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Suppress default access logs for cleanliness
        pass

    def send_json(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def send_html(self, html, status=200):
        body = html.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        params = urllib.parse.parse_qs(parsed.query)

        if path == "/":
            self.send_html(DASHBOARD_HTML)

        elif path == "/api/services":
            self.send_json(get_services())

        elif path == "/api/tasks":
            limit = params.get("limit", ["50"])[0]
            status = params.get("status", [None])[0]
            data = get_ats_tasks(limit=int(limit), status=status)
            self.send_json(data)

        elif path == "/api/logs":
            self.send_json(get_log_files())

        elif path == "/api/logs/tail":
            log_path = params.get("path", [None])[0]
            if not log_path:
                self.send_json({"error": "missing path param"}, 400)
                return
            # Security: only allow files ending in .log under known dirs
            real = os.path.realpath(log_path)
            allowed = any(real.startswith(os.path.realpath(d)) for d in LOG_DIRS)
            if not allowed or not real.endswith(".log"):
                self.send_json({"error": "access denied"}, 403)
                return
            content = tail_file(real)
            self.send_json({"path": real, "content": content})

        else:
            self.send_response(404)
            self.end_headers()


def main():
    server = http.server.HTTPServer(("0.0.0.0", PORT), DashboardHandler)
    print(f"Ada Dashboard running on http://0.0.0.0:{PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.server_close()


if __name__ == "__main__":
    main()
