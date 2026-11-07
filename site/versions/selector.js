// The version selector and the old-version banner. Every page of every version loads this one file from the root
// of the site (the deploy adds the <script> tag, tools/site_versions.py), so a cached old build gets the current one.
// It uses only what all releases share: `.site-header`, its `.version` link, the menu button (`.nav-toggle`, whose
// aria-controls names the menu, `#sidebar`) and the tokens of _tokens.scss.
(function () {
  "use strict";
  var script = document.currentScript;
  if (!script || !window.fetch || !window.URL) return;
  var root = new URL("../", script.src);

  // selector.css is linked by the same deploy step that adds this script, so the page is styled when it runs.
  fetch(new URL("versions.json", root).href)
    .then(function (response) { return response.json(); })
    .then(start)
    .catch(function () {});

  function start(versions) {
    if (!versions.length || location.pathname.indexOf(root.pathname) !== 0) return;
    var latest = versions.filter(function (v) { return v.latest; })[0] || versions[0];
    var rest = location.pathname.slice(root.pathname.length);
    // The root is the latest release; a version's own folder starts with its path.
    var current = versions.filter(function (v) { return rest.indexOf(v.path) === 0; })[0];
    var page = current ? rest.slice(current.path.length) : rest;
    current = current || latest;

    function home(v) {
      return new URL(v.latest ? "" : v.path, root).href;
    }

    function url(v) {
      return new URL((v.latest ? "" : v.path) + page, root).href + location.hash;
    }

    // The same page in another version when it exists there, else that version's home page.
    function go(v) {
      var target = url(v);
      fetch(target.split("#")[0], { method: "HEAD" })
        .then(function (response) { return response.ok ? target : home(v); })
        .catch(function () { return home(v); })
        .then(function (href) { location.assign(href); });
    }

    var select = document.createElement("select");
    select.className = "version-select";
    select.setAttribute("aria-label", "Version");
    versions.forEach(function (v) {
      var option = document.createElement("option");
      option.value = v.version;
      option.textContent = v.version + (v.latest ? " (latest)" : "");
      option.selected = v === current;
      select.appendChild(option);
    });
    select.addEventListener("change", function () {
      go(versions.filter(function (v) { return v.version === select.value; })[0]);
    });

    // A strip under the header, for the banner of an old version. The selector sits in it only when it fits nowhere else
    // (see place()). Under the header, not above: the skip links are the first children of the header and must stay
    // the first tab stops.
    var bar = document.createElement("div");
    bar.className = "version-bar";
    if (current !== latest) {
      var note = document.createElement("span");
      var link = document.createElement("a");
      link.href = url(latest);
      link.textContent = "View this page in " + latest.version;
      link.addEventListener("click", function (event) {
        event.preventDefault();
        go(latest);
      });
      note.append(
        current.version === "dev"
          ? "This is the development documentation: it may describe changes that are not released. "
          : "This is the documentation of version " + current.version + ", not the latest release. ",
        link,
        "."
      );
      bar.setAttribute("role", "note");
      bar.appendChild(note);
    }

    var header = document.querySelector(".site-header");
    var badge = header && header.querySelector(".version");
    var phone = window.matchMedia("(max-width: 30rem)");

    // The menu the button opens, when the button shows: a phone has no room for the selector in the header (the search
    // box and the buttons need it). Every release has the button and its menu; one where the button is hidden has no
    // drawer, and the selector goes to the strip.
    function menu() {
      var toggle = header && header.querySelector(".nav-toggle");
      var target = toggle && document.getElementById(toggle.getAttribute("aria-controls"));
      return target && toggle.getClientRects().length ? target : null;
    }

    function place() {
      var drawer = phone.matches ? menu() : null;
      select.classList.toggle("in-menu", !!drawer);
      if (drawer) {
        drawer.insertBefore(select, drawer.firstChild);
      } else if (header && !phone.matches) {
        header.insertBefore(select, badge || null);
      } else {
        bar.appendChild(select);
      }
      if (!bar.parentNode) {
        if (header) header.parentNode.insertBefore(bar, header.nextSibling);
        else document.body.insertBefore(bar, document.body.firstChild);
      }
      bar.hidden = !bar.children.length;
    }

    // The selector shows the version, so the header's own badge goes (selector.css; some releases show it again on a
    // phone, so the `hidden` attribute would lose to their CSS).
    document.documentElement.classList.add("has-version-select");
    place();
    if (phone.addEventListener) phone.addEventListener("change", place);
    // Back to this page from another version: the browser may restore the page with the old selection.
    window.addEventListener("pageshow", function () { select.value = current.version; });
  }
})();
