import { useState } from 'react';

export default function NewTab({apps, openApps, onChoose}: {
  apps: {id: string; name: string; description?: string}[];
  openApps: string[];
  onChoose(id: string): void;
}) {
  const [search, setSearch] = useState('');
  const matches = apps.filter(app => `${app.name} ${app.description || ''}`.toLowerCase().includes(search.trim().toLowerCase()));
  return <section className="new-tab-page" aria-label="New tab">
    <div className="new-tab-content">
      <span className="eyebrow">YOUR WORKSPACE</span>
      <h1>What would you like to open?</h1>
      <form onSubmit={event => {event.preventDefault(); if (matches[0]) onChoose(matches[0].id);}}>
        <input type="search" aria-label="Search apps" placeholder="Search apps…" autoFocus
          value={search} onChange={event => setSearch(event.target.value)} />
      </form>
      <div className="workspace-picker-apps">
        {matches.map(app => <button key={app.id} onClick={() => onChoose(app.id)}>
          <strong>{app.name}</strong>
          <span>{openApps.includes(app.id) ? 'Switch to open app' : app.description}</span>
        </button>)}
      </div>
      {!matches.length && <p role="status">No apps match “{search}”.</p>}
    </div>
  </section>;
}
