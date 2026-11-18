import { useEffect, useRef } from 'react';

export interface WorkspaceTab {
  id: string;
  title: string;
  kind: 'app' | 'new';
}

export default function WorkspaceTabs({tabs, activeId, onSelect, onClose, onNew}: {
  tabs: WorkspaceTab[];
  activeId?: string;
  onSelect(id: string): void;
  onClose(id: string): void;
  onNew(): void;
}) {
  const strip = useRef<HTMLDivElement>(null);
  useEffect(() => {
    strip.current?.querySelector('.workspace-tab.selected')?.scrollIntoView({block:'nearest', inline:'nearest'});
  }, [activeId, tabs.length]);
  return <>
    <div className="workspace-tabs" role="tablist" aria-label="Open apps and pages" ref={strip}>
      {tabs.map((tab, index) => <div className={`workspace-tab ${tab.id === activeId ? 'selected' : ''}`} key={tab.id}>
        <button role="tab" aria-selected={tab.id === activeId} title={tab.title}
          tabIndex={tab.id === activeId || (!activeId && index === 0) ? 0 : -1}
          onClick={() => onSelect(tab.id)} onKeyDown={event => {
            const offset = event.key === 'ArrowRight' ? 1 : event.key === 'ArrowLeft' ? -1 : 0;
            if (offset) {
              event.preventDefault();
              const next = (index + offset + tabs.length) % tabs.length;
              onSelect(tabs[next].id);
              strip.current?.querySelectorAll<HTMLButtonElement>('[role=tab]')[next]?.focus();
            } else if (event.key === 'Delete') { event.preventDefault(); onClose(tab.id); }
          }}>
          <span aria-hidden="true">{tab.kind === 'new' ? '+' : '▤'}</span><span>{tab.title}</span>
        </button>
        <button className="tab-close" aria-label={`Close ${tab.title}`} onClick={() => onClose(tab.id)}>×</button>
      </div>)}
    </div>
    <button className="new-tab-button" aria-label="New tab" title="New tab" onClick={onNew}>+</button>
  </>;
}
