// The version selector and the old-version banner. Every page of every version loads this one file from the root
// of the site (the deploy adds the <script> tag, tools/site_versions.py), so a cached old build gets the current one.
// It uses only what all releases share: `.site-header`, its `.version` link and the tokens of _tokens.scss.
(function () {
  "use strict";
  var script = document.currentScript;
  if (!script || !window.fetch || !window.URL) return;
  var root = new URL("../", script.src);

  var css = document.createElement("link");
  css.rel = "stylesheet";
  css.href = new URL("selector.css", script.src).href;
  document.head.appendChild(css);

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

    // A strip above the header: the banner of an old version, and on a phone the selector, which has no room in the
    // header there (the search box and the buttons need it).
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

    function place() {
      if (header && !phone.matches) {
        header.insertBefore(select, badge || null);
        if (badge) badge.hidden = true;
      } else {
        bar.appendChild(select);
      }
      if (!bar.parentNode) document.body.insertBefore(bar, document.body.firstChild);
      bar.hidden = !bar.children.length;
    }

    place();
    if (phone.addEventListener) phone.addEventListener("change", place);
  }
})();
