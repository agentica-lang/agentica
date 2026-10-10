const navButton = document.querySelector(".nav-toggle");
const sidebar = document.getElementById("sidebar");
if (navButton && sidebar) {
  navButton.addEventListener("click", () => {
    navButton.setAttribute("aria-expanded", String(sidebar.classList.toggle("open")));
  });
}
