document.querySelectorAll('a[href^="#"]').forEach((link) => {
  link.addEventListener("click", (event) => {
    const target = document.querySelector(link.getAttribute("href"));
    if (!target) {
      return;
    }

    event.preventDefault();
    target.scrollIntoView({ behavior: "smooth", block: "start" });
  });
});

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

if (!reduceMotion && "IntersectionObserver" in window) {
  const revealTargets = document.querySelectorAll(
    [
      ".hero-copy",
      ".desktop-scene",
      ".section-intro",
      ".proof-card",
      ".workflow-card",
      ".finder-copy",
      ".finder-panel",
      ".tools article",
      ".trust article",
      ".community article",
      ".price-card",
      ".context-card",
      ".faq-list details"
    ].join(", ")
  );

  revealTargets.forEach((target, index) => {
    target.classList.add("reveal-on-scroll");
    target.style.setProperty("--reveal-delay", `${Math.min(index % 4, 3) * 70}ms`);
  });

  const revealObserver = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) {
          return;
        }

        entry.target.classList.add("is-visible");
        revealObserver.unobserve(entry.target);
      });
    },
    {
      rootMargin: "0px 0px -12% 0px",
      threshold: 0.16
    }
  );

  revealTargets.forEach((target) => revealObserver.observe(target));
} else {
  document.querySelectorAll(".reveal-on-scroll").forEach((target) => {
    target.classList.add("is-visible");
  });
}
