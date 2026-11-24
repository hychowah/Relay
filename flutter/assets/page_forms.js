// Lists and fills the form fields of the page in a Browser tab, for the
// agent's browser.form and browser.fill (desktop only). Relay runs this file
// as one expression: (script)("read"), (script)("token") or
// (script)("fill", {token, fields: [{id, value}]}).
//
// Relay itself clicks no button or link, presses no key, and calls neither
// submit() nor requestSubmit(). It sets values as typing does and ticks boxes
// with a click, so a page whose own scripts react to a change can still
// submit its form or move on; a fill reports a submit it saw.
//
// A read lists only fields a person can see, with values only for choices
// (a text field says only whether it is empty), and keeps its fields in the
// page under a new random token. A fill must bring that token, from the same
// address, and finds fields only through it, so it cannot reach a button, a
// page left by Back or a field that changed since. Password and file fields
// are listed but never filled. Fields inside another site's frame cannot be
// reached; they are only counted.
(action, request) => {
  const readKey = Symbol.for("relay.formRead");
  const textTypes = new Set(["text", "email", "tel", "url", "search", "number",
    "date", "datetime-local", "month", "week", "time"]);
  const leftToUser = new Set(["password", "file"]);
  const clip = (value, most = 200) => String(value ?? "").replace(/\s+/g, " ").trim().slice(0, most);
  // The socket to Relay takes 256 KB; the reply stays well under it.
  const mostBytes = 200000;

  function kind(el) {
    if (el.tagName === "TEXTAREA") return "textarea";
    if (el.tagName === "SELECT") return "select";
    if (el.tagName !== "INPUT") return null;
    const type = el.type;
    return textTypes.has(type) || type === "checkbox" || type === "radio" || leftToUser.has(type) ? type : null;
  }

  // Whether an element draws: laid out, visible, not see-through on itself
  // or any ancestor, and more than a dot (screen-reader-only text is 1 px).
  function draws(el) {
    const view = el.ownerDocument.defaultView;
    if (!el.isConnected || !el.getClientRects().length || view.getComputedStyle(el).visibility !== "visible") return false;
    for (let node = el; node; node = node.parentElement)
      if (Number(view.getComputedStyle(node).opacity) < 0.1) return false;
    const box = el.getBoundingClientRect();
    return box.width >= 4 && box.height >= 4;
  }

  // Whether a person can see [el]: it draws, its centre lies inside the page
  // and nothing covers it there (a label over its own field is fine), and
  // the same holds for the frame it is in. The hit test also catches fields
  // clipped away by clip-path, clip or an ancestor's overflow. A field off
  // screen is scrolled to for the test and every scroll put back at once,
  // within this one script, so nothing moves on screen.
  let seen = null;
  function visible(el) {
    if (seen?.has(el)) return seen.get(el);
    const answer = visibleNow(el);
    seen?.set(el, answer);
    return answer;
  }
  function visibleNow(el) {
    if (!draws(el)) return false;
    const frame = el.ownerDocument.defaultView.frameElement;
    if (frame && !visible(frame)) return false;
    const scrolls = [];
    for (let node = el; node; node = node.ownerDocument.defaultView.frameElement)
      for (let parent = node.parentElement; parent; parent = parent.parentElement)
        scrolls.push([parent, parent.scrollLeft, parent.scrollTop]);
    try {
      const view = el.ownerDocument.defaultView;
      const centre = () => {
        const box = el.getBoundingClientRect();
        return [box.left + box.width / 2, box.top + box.height / 2];
      };
      let [x, y] = centre();
      if (x < 0 || y < 0 || x >= view.innerWidth || y >= view.innerHeight) {
        el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
        [x, y] = centre();
      }
      const hit = el.ownerDocument.elementFromPoint(x, y);
      return !!hit && (el.contains(hit) || [...(el.labels ?? [])].some((label) => label.contains(hit)));
    } finally {
      for (const [node, left, top] of scrolls)
        if (node.scrollLeft !== left || node.scrollTop !== top) node.scrollTo({ left, top, behavior: "instant" });
    }
  }

  // A styled check box or radio often hides its own box and shows its label
  // instead; a shown label with text counts as the box being shown.
  const shown = (el) => visible(el) || ((el.type === "checkbox" || el.type === "radio" || el.type === "file")
    && [...(el.labels ?? [])].some((label) => textOf(label) && visible(label)));

  // The text a person sees in [node], leaving out what does not draw and a
  // list's options or a text area's text inside a label.
  function textOf(node) {
    return clip([...node.childNodes].map((child) => child.nodeType === Node.TEXT_NODE ? child.data
      : child.nodeType === Node.ELEMENT_NODE && !/^(SELECT|TEXTAREA|SCRIPT|STYLE)$/.test(child.tagName) && draws(child)
        ? textOf(child) : "").join(""));
  }
  function labelOf(el) {
    const ids = el.getAttribute("aria-labelledby");
    const labels = ids ? ids.split(/\s+/).map((id) => el.ownerDocument.getElementById(id)).filter(Boolean) : [...(el.labels ?? [])];
    return clip(labels.filter(draws).map(textOf).join(" "));
  }
  function legendOf(el) {
    const legend = el.closest("fieldset")?.querySelector("legend");
    return legend && draws(legend) ? textOf(legend) : "";
  }
  function refusal(el, type) {
    if (type === "password") return "Password fields are left to the user.";
    if (type === "file") return "File uploads are left to the user.";
    if (el.matches(":disabled")) return "The field is disabled.";
    if (el.readOnly) return "The field is read-only.";
    if (!shown(el)) return "The field is not shown on the page.";
    return null;
  }
  // A radio group is one field: radios with one name in one form.
  const radiosOf = (el) => !el.name ? [el] : [...el.ownerDocument.querySelectorAll("input[type=radio]")]
    .filter((radio) => radio.name === el.name && radio.form === el.form);
  const signature = (el, type) => JSON.stringify([type, el.name, labelOf(el)]);
  const bytes = (value) => new TextEncoder().encode(JSON.stringify(value)).length;
  const current = () => window[readKey]?.url === location.href ? window[readKey] : null;

  if (action === "read") return read();
  if (action === "token") return { token: current()?.token ?? null };
  if (action === "fill") return fill(request ?? {});
  throw new Error("Unknown form action.");

  // The page and its shown same-site frames; shown frames of other sites are counted.
  function documents() {
    const found = [];
    let otherSiteFrames = 0;
    (function collect(doc) {
      found.push(doc);
      for (const frame of doc.querySelectorAll("iframe,frame")) {
        if (!visible(frame)) continue;
        let inner = null;
        try { inner = frame.contentDocument; } catch (_) { /* another site */ }
        if (inner) collect(inner);
        else otherSiteFrames++;
      }
    })(document);
    return { found, otherSiteFrames };
  }

  function read() {
    // Nothing changes while the page is read, so each answer holds for this read.
    seen = new Map();
    const { found, otherSiteFrames } = documents();
    const token = [...crypto.getRandomValues(new Uint8Array(16))].map((b) => b.toString(16).padStart(2, "0")).join("");
    const kept = new Map(), fields = [], forms = new Map(), grouped = new Set();
    function formOf(el) {
      const form = el.form;
      if (!form) return undefined;
      if (!forms.has(form)) {
        let action = "";
        try { action = new URL(form.getAttribute("action") || "", el.ownerDocument.baseURI).href; } catch (_) { /* unreadable */ }
        forms.set(form, { form: "form" + (forms.size + 1), action: action.slice(0, 500) });
      }
      return forms.get(form).form;
    }
    for (const doc of found) {
      for (const el of doc.querySelectorAll("input,textarea,select")) {
        if (fields.length > 300) break;
        const type = kind(el);
        if (!type || grouped.has(el) || !shown(el)) continue;
        const group = type === "radio" ? radiosOf(el).filter(shown) : [el];
        group.forEach((radio) => grouped.add(radio));
        const id = "f" + (fields.length + 1);
        const field = { id, type, form: formOf(el),
          label: type === "radio" ? legendOf(el) : labelOf(el),
          name: clip(el.name, 100), placeholder: clip(el.getAttribute("placeholder"), 100), required: group.some((r) => r.required) };
        const why = group.every((member) => refusal(member, type)) ? refusal(el, type) : null;
        if (why) Object.assign(field, { fillable: false, reason: why });
        if (type === "checkbox") field.checked = el.checked;
        else if (type === "radio") {
          field.value = clip(group.find((radio) => radio.checked)?.value, 100);
          field.options = group.map((radio) => ({ value: clip(radio.value, 100), label: labelOf(radio),
            ...(refusal(radio, type) ? { fillable: false } : {}) }));
        } else if (type === "select") {
          field.value = clip(el.value, 100);
          field.options = [...el.options].map((option) => ({ value: clip(option.value, 100), label: clip(option.text, 100),
            ...(option.matches(":disabled") ? { fillable: false } : {}) }));
        } else if (type !== "password") field.empty = el.value === "";
        for (const key of ["label", "name", "placeholder", "form"]) if (!field[key]) delete field[key];
        fields.push(field);
        kept.set(id, { elements: group, type, signatures: group.map((member) => signature(member, type)) });
      }
    }
    const reply = { token, url: location.href.slice(0, 2000), title: clip(document.title), forms: [...forms.values()],
      fields: [], otherSiteFrames, truncated: true };
    let size = bytes(reply);
    for (const field of fields) {
      size += bytes(field) + 1;
      if (reply.fields.length >= 300 || size > mostBytes) break;
      reply.fields.push(field);
    }
    for (const field of fields.slice(reply.fields.length)) kept.delete(field.id);
    reply.forms = reply.forms.filter((form) => reply.fields.some((field) => field.form === form.form));
    if (reply.fields.length === fields.length) delete reply.truncated;
    window[readKey] = { token, url: location.href, fields: kept };
    return reply;
  }

  function fill({ token, fields: changes }) {
    const read = current();
    if (!read || typeof token !== "string" || read.token !== token)
      return { error: "The page changed since browser.form; read the form again." };
    const { found } = documents();
    // A submit the page's own scripts start while a field changes is noted, not stopped.
    let pageSubmitted = false;
    const noteSubmit = () => { pageSubmitted = true; };
    const submits = found.map((doc) => {
      const forms = doc.defaultView.HTMLFormElement.prototype, submit = forms.submit;
      forms.submit = function (...args) { pageSubmitted = true; return submit.apply(this, args); };
      doc.addEventListener("submit", noteSubmit, true);
      return () => { forms.submit = submit; doc.removeEventListener("submit", noteSubmit, true); };
    });
    const results = [], filled = [];
    try {
      for (const change of (Array.isArray(changes) ? changes : []).slice(0, 300)) {
        const id = String(change?.id ?? "");
        const { element, ...result } = fillOne(read.fields.get(id), change?.value);
        results.push({ id, ...result });
        if (element) filled.push(element);
      }
    } finally {
      submits.forEach((restore) => restore());
    }
    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    filled[0]?.scrollIntoView({ block: "center", behavior: reduce ? "auto" : "smooth" });
    return { results, filled: filled.length, ...(pageSubmitted ? { pageSubmitted } : {}) };
  }

  function fillOne(field, value) {
    if (!field) return { status: "not found", reason: "browser.form listed no field with this id." };
    const { elements, type, signatures } = field;
    if (elements.some((el, i) => !el.isConnected || kind(el) !== type || signature(el, type) !== signatures[i]))
      return { status: "refused", reason: "This field changed since browser.form; read the form again." };
    const text = typeof value === "string" ? value : typeof value === "boolean" || typeof value === "number" ? String(value) : null;
    if (text === null) return { status: "refused", reason: "The value must be text, a number or true/false." };

    if (type === "radio") {
      const wanted = text.trim().toLowerCase();
      const choice = elements.find((radio) => radio.value === text) ?? elements.find((radio) => labelOf(radio).toLowerCase() === wanted);
      if (!choice) return { status: "refused", reason: "No option matches; use a listed option's value or label." };
      return tick(choice, true, type);
    }
    const [el] = elements;
    const why = refusal(el, type);
    if (why) return { status: "refused", reason: why };
    if (type === "checkbox") {
      const word = text.trim().toLowerCase();
      const on = /^(true|yes|on|1|checked|ticked)$/.test(word), off = /^(false|no|off|0|unchecked|unticked)$/.test(word);
      if (!on && !off) return { status: "refused", reason: "Use true to tick this box or false to clear it." };
      return tick(el, on, type);
    }

    const before = el.value;
    let wanted = text;
    if (type === "select") {
      const options = [...el.options];
      const option = options.find((o) => o.value === text) ?? options.find((o) => clip(o.text).toLowerCase() === text.trim().toLowerCase());
      if (!option || option.matches(":disabled")) return { status: "refused", reason: "No option matches; use a listed option's value or label." };
      wanted = option.value;
    }
    setValue(el, wanted);
    if (el.value !== wanted) {
      setValue(el, before);
      return { status: "refused", reason: textTypes.has(type) && type !== "text"
        ? `The field did not take this value; a ${type} field needs its own format (dates as YYYY-MM-DD).`
        : "The field did not take this value." };
    }
    mark([el]);
    return { status: "filled", element: el };
  }

  // A check box or radio changes as a click on it would, so pages that only
  // follow clicks see it too; clicking a box does not submit a form.
  function tick(box, on, type) {
    const why = refusal(box, type);
    if (why) return { status: "refused", reason: why };
    if (box.checked !== on) box.click();
    if (box.checked !== on) return { status: "refused", reason: "The page did not let this change." };
    mark([box, ...(box.labels ?? [])]);
    return { status: "filled", element: box };
  }

  // Sets the value as typing does, through the element's own value setter,
  // so frameworks that track it (React) see the change, then says so.
  function setValue(el, value) {
    const view = el.ownerDocument.defaultView;
    const proto = el.tagName === "TEXTAREA" ? view.HTMLTextAreaElement : el.tagName === "SELECT" ? view.HTMLSelectElement : view.HTMLInputElement;
    Object.getOwnPropertyDescriptor(proto.prototype, "value").set.call(el, value);
    el.dispatchEvent(new view.Event("input", { bubbles: true }));
    el.dispatchEvent(new view.Event("change", { bubbles: true }));
  }

  // The outline shows the user which fields to check before they submit. It
  // comes from a style sheet Relay adds, so the page's own inline styles stay
  // as they were, and it stays on every field filled on this page.
  function mark(elements) {
    for (const el of elements) {
      const doc = el.ownerDocument;
      if (!doc.adoptedStyleSheets.some((sheet) => sheet[readKey])) {
        const sheet = new doc.defaultView.CSSStyleSheet();
        sheet.replaceSync("[data-relay-filled]{outline:3px solid #0a84ff !important;outline-offset:2px !important}");
        sheet[readKey] = true;
        doc.adoptedStyleSheets = [...doc.adoptedStyleSheets, sheet];
      }
      el.setAttribute("data-relay-filled", "");
    }
  }
}
