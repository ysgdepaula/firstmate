/* « Il manque de toi », le seul endroit ou la page touche a une decision.
   Les deux pages (projets, a valider) injectent ce meme bloc, donc ce qu'un
   clic fait est decrit une seule fois.

   Regle du capitaine, inchangee : rien n'agit depuis la page. Un clic MET EN
   FILE un prompt Lavish et s'arrete la ; c'est le capitaine qui envoie la file
   quand il a fini, et firstmate lui repose la question en chat avant d'agir.
   Le contexte porte projet/decision/choix/nature (jamais le couple question/answer que
   l'entree a cle lit), donc meme une source liee ne pourrait rien clore.

   Deux prompts sortent d'ici :
     tag "choice"        un choix ferme sur une decision
     tag "create-lavish" une demande de page dediee pour la selection cochee
   Les deux sont des demandes, jamais des reponses enregistrees.

   Attend de la page hote : el, link, tag, utf8ByteLength. */

var SELECT_HINT = "coche une ou plusieurs décisions pour demander une page qui les traite ensemble.";

function frDay(iso) {
  var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso || "");
  return m ? m[3] + "/" + m[2] : null;
}

/* Une seule porte vers Lavish : rend true quand le prompt est bien entre dans
   la file, false sinon. La page ouverte hors Lavish n'a pas de file du tout et
   doit le dire au lieu de faire croire a un envoi. */
function queueToLavish(text, context) {
  if (!window.lavish || typeof window.lavish.queuePrompt !== "function") return false;
  if (utf8ByteLength(text) > 512) text = text.slice(0, 200);
  try {
    return window.lavish.queuePrompt(text, context) !== false;
  } catch (e) {
    return false;
  }
}

function decisionMessage(current, previous) {
  var s = "en file : " + current;
  if (previous && previous !== current) {
    s += ", à la place de " + previous
      + " (la page ne peut pas retirer une ligne déjà en file : corrige-la dans Lavish avant d'envoyer)";
  }
  return s + ". Rien n'est envoyé tant que tu n'envoies pas la file depuis Lavish, "
    + "et rien n'est clos tant que firstmate ne te l'a pas reconfirmé en chat.";
}

/* Le bloc complet d'un projet : une ligne par decision, puis le bouton de
   groupe qui demande une page dediee pour les cases cochees. */
function renderDecisions(body, project, rows) {
  var ul = el("ul", "you");
  var selected = [];

  rows.forEach(function (r) {
    var li = el("li", "");
    li.setAttribute("data-decision", r.key);
    if (r.kind) li.setAttribute("data-kind", r.kind);
    if (r.nature) li.setAttribute("data-nature", r.nature);

    var q = el("span", "q");
    var box = el("input", "pick");
    box.type = "checkbox";
    box.setAttribute("data-select", r.key);
    box.setAttribute("aria-label", "choisir cette décision pour une page dédiée");
    q.appendChild(box);
    q.appendChild(link(r.question, r.url, "", r.url_refused));
    if (r.kind) q.appendChild(tag(r.kind));
    if (r.ask) q.appendChild(el("span", "ask", r.ask));
    var since = frDay(r.since);
    if (since) q.appendChild(tag("depuis le " + since));
    li.appendChild(q);

    /* Le lien direct vers la page de la decision, ou le trou nomme : appuyer
       sur un choix sans avoir pu voir la page est exactement ce que le
       capitaine ne veut plus. */
    var open = el("span", "page");
    if (r.page && r.page.url) {
      var a = link("ouvrir la page", r.page.url, "go");
      a.setAttribute("data-page", r.key);
      open.appendChild(a);
    } else {
      open.appendChild(el("span", "dim", "pas de page dédiée"));
    }
    li.appendChild(open);

    var btns = el("div", "btns");
    var ok = el("span", "ok");
    var chosen = null;
    var buttons = [];
    r.options.forEach(function (o) {
      var b = el("button", "btn", o.label);
      b.type = "button";
      b.setAttribute("data-choice", o.value);
      b.addEventListener("click", function () {
        var text = "Projets · " + project.name + " · " + r.question + " : " + o.label;
        if (!queueToLavish(text, {
          tag: "choice", text: project.name + " : " + r.question + " -> " + o.label, element: li,
          queueKey: "projets:" + project.id + ":" + r.key,
          data: { projet: project.id, decision: r.key, choix: o.value, nature: r.nature || "decision" }
        })) {
          li.className = "refused";
          ok.textContent = "non mis en file : ouvre cette page dans Lavish";
          return;
        }
        li.className = "queued";
        ok.textContent = decisionMessage(o.label, chosen);
        chosen = o.label;
        buttons.forEach(function (other) {
          other.className = other === b ? "btn on" : "btn";
        });
      });
      buttons.push(b);
      btns.appendChild(b);
    });
    li.appendChild(btns);
    li.appendChild(ok);

    box.addEventListener("change", function () {
      var at = selected.indexOf(r);
      if (box.checked && at < 0) selected.push(r);
      else if (!box.checked && at >= 0) selected.splice(at, 1);
      refresh();
    });
    ul.appendChild(li);
  });
  body.appendChild(ul);

  /* Demander UNE page qui traite plusieurs decisions ensemble. La page ne
     fabrique rien : elle met la demande en file, firstmate la reprend en chat. */
  var group = el("div", "group");
  var make = el("button", "btn make", "créer une page Lavish pour la sélection");
  make.type = "button";
  make.setAttribute("data-create-lavish", project.id);
  make.disabled = true;
  var count = el("span", "src", SELECT_HINT);
  function refresh() {
    make.disabled = selected.length === 0;
    count.textContent = selected.length === 0
      ? SELECT_HINT
      : selected.length + (selected.length > 1 ? " décisions sélectionnées." : " décision sélectionnée.");
  }
  make.addEventListener("click", function () {
    if (!selected.length) return;
    var titres = selected.map(function (r) { return r.question; });
    var text = "Projets · " + project.name + " · créer une page Lavish pour : " + titres.join(" ; ");
    if (!queueToLavish(text, {
      tag: "create-lavish", text: project.name + " : page à créer pour " + selected.length + " décision(s)",
      element: group, queueKey: "projets:create-lavish:" + project.id,
      data: { projet: project.id, decisions: selected.map(function (r) { return r.key; }), titres: titres }
    })) {
      group.className = "group refused";
      count.textContent = "non mis en file : ouvre cette page dans Lavish";
      return;
    }
    group.className = "group queued";
    count.textContent = "demande en file pour " + selected.length + (selected.length > 1 ? " décisions" : " décision")
      + ". Rien n'est fabriqué tant que tu n'envoies pas la file depuis Lavish, "
      + "et firstmate te reposera la question en chat avant de lancer le travail.";
  });
  group.appendChild(make);
  group.appendChild(count);
  body.appendChild(group);
}
