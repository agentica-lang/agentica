const navButton = document.querySelector(".nav-toggle");
const sidebar = document.getElementById("sidebar");
if (navButton && sidebar) {
  const setOpen = (open) => {
    sidebar.classList.toggle("open", open);
    document.documentElement.classList.toggle("nav-open", open);
    navButton.setAttribute("aria-expanded", String(open));
  };
  navButton.addEventListener("click", () => {
    setOpen(!sidebar.classList.contains("open"));
  });
  sidebar.addEventListener("click", (event) => {
    if (event.target.closest("a")) setOpen(false);
  });
  document.addEventListener("keydown", (event) => {
    if (event.key === "Escape" && sidebar.classList.contains("open")) {
      setOpen(false);
      navButton.focus();
    }
  });
}
