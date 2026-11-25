import { invoke, isTauri } from "@tauri-apps/api/core";
import { useLayoutEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import "./style.css";

const wallets = Array.from({ length: 100 }, (_, index) => ({
  id: `LAB-${String(index + 1).padStart(3, "0")}`,
  label: `Fictional wallet ${index + 1}`,
}));

function App() {
  const [selected, setSelected] = useState<string[]>([]);
  const [status, setStatus] = useState("Ready");
  const [pending, setPending] = useState(false);

  useLayoutEffect(() => {
    performance.mark("roster-rendered");
  }, []);

  function toggle(id: string) {
    setSelected((current) =>
      current.includes(id) ? current.filter((item) => item !== id) : [...current, id],
    );
  }

  async function ping() {
    setPending(true);
    setStatus("Checking local IPC…");
    try {
      if (!isTauri()) {
        throw new Error("IPC requires the desktop application.");
      }
      setStatus(await invoke<string>("local_ping"));
    } catch (error) {
      setStatus(error instanceof Error ? error.message : String(error));
    } finally {
      setPending(false);
    }
  }

  return (
    <main>
      <h1>Synthetic wallet roster</h1>
      <div className="actions">
        <span aria-live="polite">{selected.length} selected</span>
        <button disabled={selected.length === 0} onClick={() => setSelected([])}>Clear</button>
        <button disabled={pending} onClick={ping}>Test local IPC</button>
        <span role="status">{status}</span>
      </div>
      <table>
        <thead><tr><th scope="col">Select</th><th scope="col">ID</th><th scope="col">Label</th></tr></thead>
        <tbody>
          {wallets.map(({ id, label }) => (
            <tr key={id}>
              <td><input type="checkbox" aria-label={`Select ${id}`} checked={selected.includes(id)} onChange={() => toggle(id)} /></td>
              <td>{id}</td>
              <td>{label}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </main>
  );
}

createRoot(document.getElementById("root")!).render(<App />);
