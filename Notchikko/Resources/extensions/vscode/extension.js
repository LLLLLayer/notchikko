const vscode = require("vscode");
const http = require("http");

const PORT_BASE = 23456;
const PORT_RANGE = 5;

let server = null;

async function focusTerminalByPids(pids) {
  for (const terminal of vscode.window.terminals) {
    const termPid = await terminal.processId;
    if (termPid && pids.includes(termPid)) {
      // false = take focus, brings the correct window to the front
      terminal.show(false);
      // Also ensure the window itself is focused
      await vscode.commands.executeCommand("workbench.action.focusActiveEditorGroup");
      return true;
    }
  }
  return false;
}

function tryListen(port, maxPort) {
  if (port > maxPort) {
    console.log("Notchikko terminal-focus: all ports in use");
    return;
  }

  server = http.createServer((req, res) => {
    if (req.method === "POST" && req.url === "/focus-tab") {
      let body = "";
      req.on("data", (chunk) => { body += chunk; });
      req.on("end", () => {
        try {
          const data = JSON.parse(body);
          const pids = Array.isArray(data.pids) ? data.pids.filter(Number.isFinite) : [];
          if (pids.length) {
            focusTerminalByPids(pids).then((found) => {
              res.writeHead(found ? 200 : 404);
              res.end(found ? "ok" : "not found");
            });
          } else {
            res.writeHead(400);
            res.end("no pids");
          }
        } catch {
          res.writeHead(400);
          res.end("bad json");
        }
      });
    } else {
      res.writeHead(404);
      res.end();
    }
  });

  server.on("error", (err) => {
    if (err.code === "EADDRINUSE") {
      server = null;
      tryListen(port + 1, maxPort);
    }
  });

  server.listen(port, "127.0.0.1", () => {
    console.log(`Notchikko terminal-focus: listening on 127.0.0.1:${port}`);
  });
}

function activate(context) {
  tryListen(PORT_BASE, PORT_BASE + PORT_RANGE - 1);
}

function deactivate() {
  if (server) {
    server.close();
    server = null;
  }
}

module.exports = { activate, deactivate };
