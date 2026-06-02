const heatmap = document.querySelector(".heatmap");

if (heatmap) {
  let phase = 0;
  window.setInterval(() => {
    phase = (phase + 1) % 32;
    heatmap.style.backgroundPosition = `${phase}px 0, ${phase * 0.35}px 0, 0 0`;
  }, 120);
}
