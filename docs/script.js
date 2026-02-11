const hueButtons = [...document.querySelectorAll(".theme-dot[data-hue]")];
const modeButtons = [...document.querySelectorAll(".mode-dot[data-mode]")];
const ambientElements = [...document.querySelectorAll(".ambient")];
const revealTargets = [...document.querySelectorAll(".reveal")];
const prefersReducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
document.body.classList.add("js-ready");

const modeTokens = {
  light: {
    "--bg": "#f8f4eb",
    "--bg-alt": "#e9dfcf",
    "--surface": "#fffaf0",
    "--text": "#221d19",
    "--muted": "#665345",
    "--line": "rgba(34, 29, 25, 0.18)",
    "--code-bg": "#1f1b19",
    "--code-text": "#f7eee5",
  },
  dark: {
    "--bg": "#121316",
    "--bg-alt": "#21242b",
    "--surface": "#1b1f27",
    "--text": "#ecedf1",
    "--muted": "#a9afbd",
    "--line": "rgba(236, 237, 241, 0.23)",
    "--code-bg": "#090b11",
    "--code-text": "#e5ebff",
  },
};

const hueTokens = {
  red: {
    "--accent": "#d72f44",
    "--accent-soft": "#ff6f61",
    "--accent-ink": "#fff7ea",
    "--hero-wash-a": "rgba(255, 111, 97, 0.32)",
    "--hero-wash-b": "rgba(215, 47, 68, 0.24)",
  },
  orange: {
    "--accent": "#ff6d1f",
    "--accent-soft": "#ffb347",
    "--accent-ink": "#2b1805",
    "--hero-wash-a": "rgba(255, 179, 71, 0.36)",
    "--hero-wash-b": "rgba(255, 109, 31, 0.24)",
  },
  yellow: {
    "--accent": "#e1aa00",
    "--accent-soft": "#ffe05d",
    "--accent-ink": "#2d2600",
    "--hero-wash-a": "rgba(255, 224, 93, 0.34)",
    "--hero-wash-b": "rgba(225, 170, 0, 0.23)",
  },
  green: {
    "--accent": "#1b9a59",
    "--accent-soft": "#58d68d",
    "--accent-ink": "#f5fff9",
    "--hero-wash-a": "rgba(88, 214, 141, 0.34)",
    "--hero-wash-b": "rgba(27, 154, 89, 0.23)",
  },
  blue: {
    "--accent": "#2563eb",
    "--accent-soft": "#60a5fa",
    "--accent-ink": "#eff6ff",
    "--hero-wash-a": "rgba(96, 165, 250, 0.31)",
    "--hero-wash-b": "rgba(37, 99, 235, 0.22)",
  },
  purple: {
    "--accent": "#7c3aed",
    "--accent-soft": "#c084fc",
    "--accent-ink": "#f7f0ff",
    "--hero-wash-a": "rgba(192, 132, 252, 0.31)",
    "--hero-wash-b": "rgba(124, 58, 237, 0.22)",
  },
};

const state = {
  hue: "red",
  mode: "light",
};

const applyTheme = () => {
  const selectedMode = modeTokens[state.mode];
  const selectedHue = hueTokens[state.hue];
  if (!selectedMode || !selectedHue) return;

  Object.entries(selectedMode).forEach(([property, value]) => {
    document.documentElement.style.setProperty(property, value);
  });
  Object.entries(selectedHue).forEach(([property, value]) => {
    document.documentElement.style.setProperty(property, value);
  });

  hueButtons.forEach((button) => {
    button.classList.toggle("is-active", button.dataset.hue === state.hue);
    button.setAttribute("aria-pressed", button.dataset.hue === state.hue ? "true" : "false");
  });
  modeButtons.forEach((button) => {
    button.classList.toggle("is-active", button.dataset.mode === state.mode);
    button.setAttribute("aria-pressed", button.dataset.mode === state.mode ? "true" : "false");
  });
};

hueButtons.forEach((button) => {
  button.addEventListener("click", () => {
    state.hue = button.dataset.hue;
    applyTheme();
  });
});

modeButtons.forEach((button) => {
  button.addEventListener("click", () => {
    state.mode = button.dataset.mode;
    applyTheme();
  });
});

applyTheme();

if (!prefersReducedMotion && "IntersectionObserver" in window) {
  const observer = new IntersectionObserver(
    (entries) => {
      entries.forEach((entry) => {
        if (!entry.isIntersecting) return;
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      });
    },
    { threshold: 0.2 }
  );

  revealTargets.forEach((target, index) => {
    target.style.transitionDelay = `${index * 60}ms`;
    observer.observe(target);
  });
} else {
  revealTargets.forEach((target) => target.classList.add("is-visible"));
}

if (!prefersReducedMotion) {
  window.addEventListener("pointermove", (event) => {
    const x = event.clientX / window.innerWidth - 0.5;
    const y = event.clientY / window.innerHeight - 0.5;

    ambientElements.forEach((element, index) => {
      const drift = 18 + index * 8;
      element.style.transform = `translate(${x * drift}px, ${y * drift}px)`;
    });
  });
}
