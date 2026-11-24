// Lists and fills the form fields of the page in a Browser tab, for the
// agent's browser.form and browser.fill (desktop only). Relay runs this file
// as one expression: (script)("read") or (script)("fill", [{id, value}]).
//
// It never submits: it clicks no button or link, presses no key, and calls
// neither submit() nor requestSubmit(). A listed field keeps Relay's id in a
// data-relay-field attribute; a fill finds fields only by that id and fills
// only a shown, enabled, editable text field, text area, list, check box or
// radio group. Password and file fields are listed but never filled, and a
// password's value is never read. Fields inside another site's frame cannot
// be reached; they are only counted.
(action, request) => {
  const textTypes = new Set(["text", "email", "tel", "url", "search", "number",
    "date", "datetime-local", "month", "week", "time"]);
  const leftToUser = new Set(["password", "file"]);
  const clip = (value, most = 200) => String(value ?? "").replace(/\s+/g, " ").trim().slice(0, most);

  // The page and its same-site frames; frames of other sites are counted.
  const documents = [];
  let otherSiteFrames = 0;
  (function collect(doc) {
    documents.push(doc);
    for (const frame of doc.querySelectorAll("iframe,frame")) {
      let inner = null;
      try { inner = frame.contentDocument; } catch (_) { /* another site */ }
      const box = frame.getBoundingClientRect();
      if (inner) collect(inner);
      else if (box.width > 1 && box.height > 1) otherSiteFrames++;
    }
  })(document);

  function kind(el) {
    if (el.tagName === "TEXTAREA") return "textarea";
    if (el.tagName === "SELECT") return "select";
    if (el.tagName !== "INPUT") return null;
    const type = el.type;
    return textTypes.has(type) || type === "checkbox" || type === "radio" || leftToUser.has(type) ? type : null;
  }
  const shown = (el) => el.getClientRects().length > 0 &&
    el.ownerDocument.defaultView.getComputedStyle(el).visibility !== "hidden";
  function refusal(el, type) {
    if (type === "password") return "Password fields are left to the user.";
    if (type === "file") return "File uploads are left to the user.";
    if (el.matches(":disabled")) return "The field is disabled.";
    if (el.readOnly) return "The field is read-only.";
    if (!shown(el)) return "The field is not shown on the page.";
    return null;
  }
  // A label's text without a list's options or a text area's text inside it.
  const textOf = (node) => [...node.childNodes].map((child) => child.nodeType === Node.TEXT_NODE ? child.data
    : child.nodeType === Node.ELEMENT_NODE && !/^(SELECT|TEXTAREA|SCRIPT|STYLE)$/.test(child.tagName) ? textOf(child) : "").join("");
  function labelOf(el) {
    const ids = el.getAttribute("aria-labelledby");
    const named = ids && ids.split(/\s+/).map((id) => { const by = el.ownerDocument.getElementById(id); return by ? textOf(by) : ""; }).join(" ");
    return clip(el.getAttribute("aria-label") || named || [...(el.labels ?? [])].map(textOf).join(" ")
      || el.getAttribute("title"));
  }
  // A radio group is one field: radios with one name in one form.
  const radiosOf = (el) => !el.name ? [el] : [...el.ownerDocument.querySelectorAll("input[type=radio]")]
    .filter((radio) => radio.name === el.name && radio.form === el.form);

  if (action === "read") return read();
  if (action === "fill" && Array.isArray(request)) return fill(request);
  throw new Error("Unknown form action.");

  function read() {
    const fields = [], forms = new Map(), used = new Set(), grouped = new Set();
    let next = 1, size = 0, truncated = false;
    for (const doc of documents)
      for (const el of doc.querySelectorAll("[data-relay-field]"))
        next = Math.max(next, 1 + (Number(/^f(\d+)$/.exec(el.getAttribute("data-relay-field"))?.[1]) || 0));
    // An id stays with its field across reads; a copied element gets its own.
    function idFor(elements) {
      let id = elements.map((el) => el.getAttribute("data-relay-field")).find((id) => /^f\d+$/.test(id ?? "") && !used.has(id));
      id ??= "f" + next++;
      used.add(id);
      for (const el of elements) el.setAttribute("data-relay-field", id);
      return id;
    }
    function formOf(el) {
      const form = el.form;
      if (!form) return undefined;
      if (!forms.has(form)) {
        let action = "";
        try { action = new URL(form.getAttribute("action") || "", el.ownerDocument.baseURI).href; } catch (_) { /* unreadable */ }
        forms.set(form, { form: "form" + (forms.size + 1),
          name: clip(form.getAttribute("aria-label") || form.getAttribute("name") || form.getAttribute("id"), 100) || undefined,
          action: action.slice(0, 500) });
      }
      return forms.get(form).form;
    }
    for (const doc of documents) {
      for (const el of doc.querySelectorAll("input,textarea,select")) {
        const type = kind(el);
        if (!type || grouped.has(el) || !shown(el)) continue;
        const group = type === "radio" ? radiosOf(el).filter(shown) : [el];
        group.forEach((radio) => grouped.add(radio));
        const field = { id: idFor(group), type, form: formOf(el),
          label: type === "radio" ? clip(el.closest("fieldset")?.querySelector("legend")?.textContent
            || el.closest("[role=radiogroup]")?.getAttribute("aria-label") || el.name) : labelOf(el),
          name: clip(el.name, 100), placeholder: clip(el.getAttribute("placeholder"), 100), required: group.some((r) => r.required) };
        const why = group.every((member) => refusal(member, type)) ? refusal(el, type) : null;
        if (why) Object.assign(field, { fillable: false, reason: why });
        if (type === "checkbox") field.checked = el.checked;
        else if (type === "radio") {
          field.value = group.find((radio) => radio.checked)?.value ?? "";
          field.options = group.map((radio) => ({ value: clip(radio.value, 100), label: labelOf(radio),
            ...(refusal(radio, type) ? { fillable: false } : {}) }));
        } else if (type === "select") {
          field.value = clip(el.value, 100);
          const options = [...el.options];
          field.options = options.slice(0, 60).map((option) => ({ value: clip(option.value, 100), label: clip(option.text, 100) }));
          if (options.length > 60) field.moreOptions = options.length - 60;
        } else if (!leftToUser.has(type)) field.value = el.value.slice(0, 1000);
        for (const key of ["label", "name", "placeholder", "form"]) if (!field[key]) delete field[key];
        // The client's socket takes 256 KB; leave room for the rest.
        size += JSON.stringify(field).length;
        if (size > 180000 || fields.length >= 300) { truncated = true; break; }
        fields.push(field);
      }
      if (truncated) break;
    }
    return { url: location.href, title: document.title, forms: [...forms.values()], fields, otherSiteFrames,
      ...(truncated ? { truncated: true } : {}) };
  }

  function fill(changes) {
    for (const doc of documents)
      for (const el of doc.querySelectorAll("[data-relay-filled]")) {
        el.removeAttribute("data-relay-filled");
        el.style.removeProperty("outline");
        el.style.removeProperty("outline-offset");
      }
    const results = [], filled = [];
    for (const change of changes.slice(0, 300)) {
      const id = String(change?.id ?? "");
      const { element, ...result } = fillOne(id, change?.value);
      results.push({ id, ...result });
      if (element) filled.push(element);
    }
    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    filled[0]?.scrollIntoView({ block: "center", behavior: reduce ? "auto" : "smooth" });
    return { results, filled: filled.length, submitted: false };
  }

  function fillOne(id, value) {
    const found = /^f\d+$/.test(id)
      ? documents.flatMap((doc) => [...doc.querySelectorAll(`[data-relay-field="${id}"]`)]) : [];
    if (!found.length) return { status: "not found", reason: "No field has this id now; read the form again." };
    const [el] = found, type = kind(el);
    if (!type) return { status: "refused", reason: "This is not a field Relay fills." };
    const group = type === "radio" && found.every((radio) => kind(radio) === "radio" && radio.name === el.name && radio.form === el.form);
    if (found.length > 1 && !group) return { status: "refused", reason: "This id matches more than one field; read the form again." };
    const text = typeof value === "string" ? value : typeof value === "boolean" || typeof value === "number" ? String(value) : null;
    if (text === null) return { status: "refused", reason: "The value must be text, a number or true/false." };

    if (type === "radio") {
      const wanted = text.trim().toLowerCase();
      const choice = found.find((radio) => radio.value === text) ?? found.find((radio) => labelOf(radio).toLowerCase() === wanted);
      if (!choice) return { status: "refused", reason: "No option matches; use a listed option's value or label." };
      return tick(choice, true, type);
    }
    const why = refusal(el, type);
    if (why) return { status: "refused", reason: why };
    if (type === "checkbox") return tick(el, /^(true|yes|on|1|checked)$/i.test(text.trim()), type);

    const before = el.value;
    let wanted = text;
    if (type === "select") {
      const options = [...el.options];
      const option = options.find((o) => o.value === text) ?? options.find((o) => clip(o.text).toLowerCase() === text.trim().toLowerCase());
      if (!option || option.disabled) return { status: "refused", reason: "No option matches; use a listed option's value or label." };
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
  // follow clicks see it too; clicking a box never submits a form.
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

  // The outline shows the user which fields to check before they submit.
  function mark(elements) {
    for (const el of elements) {
      el.setAttribute("data-relay-filled", "");
      el.style.setProperty("outline", "3px solid #0a84ff", "important");
      el.style.setProperty("outline-offset", "2px", "important");
    }
  }
}
