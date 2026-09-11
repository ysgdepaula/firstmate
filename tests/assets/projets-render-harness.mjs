// Render a built projets page's shipped inline script under a minimal DOM shim
// and print what the renderer actually produced, so page behavior is asserted
// through the real template rather than by reading its source.
//
// Usage: node projets-render-harness.mjs <built-page.html> [click=<project-id>/<decision-key>/<choice-value>] [width=<px>]
// Prints one JSON document:
//   { error, meta, notice, badges:[{kind,value,label,soft}],
//     rail:[{id,name,count,on}],
//     cards:[{id,name,hidden,headline,blocs:[{num,title,open,empty,doing,decisions,items,cells,more}],gaps:[...]}],
//     queued:[{prompt,data,tag}] }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");
const opts = {};
for (const arg of process.argv.slice(3)) {
  const [k, v] = arg.split("=");
  opts[k] = v;
}

class Node {
  constructor(tag) {
    this.tagName = tag.toUpperCase();
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.open = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.href = "";
    this.listeners = {};
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  getAttribute(k) { return this.attributes[k]; }
  addEventListener(ev, fn) { (this.listeners[ev] = this.listeners[ev] || []).push(fn); }
  click() { (this.listeners.click || []).forEach((fn) => fn({ preventDefault() {} })); }
  all() {
    const out = [];
    const walk = (n) => { for (const c of n.children) { out.push(c); walk(c); } };
    walk(this);
    return out;
  }
  byClass(cls) { return this.all().filter((c) => c.className.split(/\s+/).includes(cls)); }
  byAttr(k, v) { return this.all().filter((c) => c.attributes[k] === v); }
  querySelectorAll(sel) { return this.byClass(sel.replace(/^\./, "")); }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="projets-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("projets-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  getElementById: (id) => {
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
  querySelector: (sel) => {
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
const queued = [];
const calls = [];
globalThis.window = {
  innerWidth: Number(opts.width || 1400),
  lavish: opts.lavish === "absent" ? undefined : {
    queuePrompt: (prompt, ctx) => { calls.push("queuePrompt"); queued.push({ prompt, data: ctx && ctx.data, tag: ctx && ctx.tag }); },
    sendQueuedPrompts: opts.lavish === "queue-only" ? undefined : () => { calls.push("sendQueuedPrompts"); if (opts.lavish === "reject") return Promise.reject(new Error("offline")); },
  },
};
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const main = byId.get("pj-main") || new Node("div");
const nav = byId.get("pj-nav") || new Node("div");
const badges = (byId.get("pj-badges") || new Node("div")).children.map((b) => ({
  kind: b.attributes["data-badge"],
  value: b.all().find((c) => c.tagName === "B")?.textContent ?? "",
  label: b.all().find((c) => c.tagName === "SMALL")?.textContent ?? "",
  soft: b.className.split(/\s+/).includes("soft"),
}));
const rail = nav.children.filter((c) => c.tagName === "BUTTON").map((b) => ({
  id: b.attributes["data-project"],
  name: b.children[0]?.textContent ?? "",
  count: Number(b.children[1]?.textContent),
  on: b.className.split(/\s+/).includes("on"),
}));

if (opts.click) {
  const [pid, key, value] = opts.click.split("/");
  const card = main.byAttr("data-project", pid)[0];
  const li = card && card.byAttr("data-decision", key)[0];
  const btn = li && li.byAttr("data-choice", value)[0];
  if (btn) btn.click();
}

await Promise.resolve();
const cards = main.children.filter((c) => c.className.split(/\s+/).includes("card")).map((card) => ({
  id: card.attributes["data-project"],
  name: card.byClass("head")[0]?.children.find((c) => c.tagName === "H2")?.textContent ?? "",
  headline: card.byClass("headline")[0]?.textContent ?? null,
  hidden: card.hidden,
  deadline: card.byClass("deadline")[0]?.textContent ?? null,
  team: card.byClass("team")[0]?.textContent ?? null,
  blocs: card.byClass("bloc").map((b) => {
    const body = b.byClass("body")[0] || new Node("div");
    return {
      text: body.textContent,
      links: body.all().filter((c) => c.tagName === "A").map((c) => c.href),
      num: Number(b.attributes["data-bloc"]),
      title: b.all().find((c) => c.tagName === "H3")?.textContent ?? "",
      open: b.open,
      empty: body.byClass("empty")[0]?.textContent ?? null,
      doing: body.all().filter((c) => c.attributes["data-doing"]).map((tr) => ({ id: tr.attributes["data-doing"], hidden: tr.hidden })),
      decisions: body.all().filter((c) => c.attributes["data-decision"]).map((li) => ({
        key: li.attributes["data-decision"],
        choices: li.all().filter((c) => c.attributes["data-choice"]).map((c) => c.attributes["data-choice"]),
        message: li.byClass("ok")[0]?.textContent ?? "",
        sent: li.className.split(/\s+/).includes("sent"),
      })),
      items: body.byClass("tl").flatMap((ul) => ul.children.map((li) => li.textContent)),
      cells: body.all().filter((c) => c.tagName === "TD").map((td) => td.textContent),
      more: body.byClass("more")[0]?.textContent ?? null,
    };
  }),
  gaps: (card.byClass("gaps")[0]?.byClass("tl")[0]?.children ?? []).map((li) => li.textContent),
}));
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .concat(main.byClass("err").map((e) => e.textContent))
  .join(" ");
const notice = byId.get("pj-notice");

process.stdout.write(JSON.stringify({
  error: errorText,
  meta: (byId.get("pj-meta") || new Node("div")).textContent,
  notice: notice && !notice.hidden ? notice.textContent : null,
  badges, rail, cards, queued, calls,
}) + "\n");
