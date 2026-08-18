// Custodia site — minimal behavior, no framework.

document.addEventListener("DOMContentLoaded", function () {
  // Mermaid architecture diagram
  if (window.mermaid) {
    mermaid.initialize({
      startOnLoad: true,
      theme: "base",
      themeVariables: {
        primaryColor: "#eef4ff",
        primaryTextColor: "#131a45",
        primaryBorderColor: "#1e2761",
        lineColor: "#8891b8",
        secondaryColor: "#fdf6ec",
        tertiaryColor: "#ffffff",
        fontFamily: "Inter, sans-serif",
      },
      flowchart: { curve: "basis", padding: 12 },
    });
  }

  // Mobile nav toggle
  var toggle = document.querySelector(".navtoggle");
  var links = document.querySelector(".navlinks");
  if (toggle && links) {
    toggle.addEventListener("click", function () {
      links.classList.toggle("open");
    });
  }

  // Close mobile nav after clicking a link
  document.querySelectorAll(".navlinks a").forEach(function (a) {
    a.addEventListener("click", function () {
      if (links) links.classList.remove("open");
    });
  });
});
