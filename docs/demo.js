// The keys under the ⇧⌘1 demo (demo.mp4, a screen recording of the real app),
// shown as they're pressed. Everything is read off the video's own clock, so
// the keys stay in step through loops, stalls and seeks.
(() => {
  const video = document.querySelector(".demo video");
  const groups = [...document.querySelectorAll(".demo .key-group")];
  if (!video || !groups.length) return;

  // It plays on its own and loops, so it can be paused; with reduced motion
  // asked for, it waits to be played.
  const player = video.closest(".player"), button = player.querySelector(".playback");
  const show = () => {
    player.classList.toggle("paused", video.paused);
    button.setAttribute("aria-label", video.paused ? "Play the demo" : "Pause the demo");
  };
  video.addEventListener("play", show);
  video.addEventListener("pause", show);
  button.addEventListener("click", () => (video.paused ? video.play() : video.pause()));
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) {
    video.autoplay = false;
    video.pause();
  }
  show();

  // When each one shows, is pressed (or moves), and goes, in the video's seconds.
  const KEYS = [
    { at: 3.3, press: 3.9, end: 4.7 },            // ⇧⌘1
    { at: 4.9, from: 5.11, to: 5.77, end: 6.05 }, // the pinch
    { at: 6.2, from: 6.44, to: 7.16, end: 8.5 },  // the drag
    { at: 9.33, press: 9.9, end: 10.85 },         // esc
  ];

  // The app's crisp spring (critically damped, perceptualDuration 0.34), and
  // a livelier one with a little bounce for things arriving.
  const OMEGA = (2 * Math.PI) / 0.34;
  const crisp = (s) => (s <= 0 ? 0 : 1 - (1 + OMEGA * s) * Math.exp(-OMEGA * s));
  const lively = (s) => {
    const w = (2 * Math.PI) / 0.42, z = 0.62, wd = w * Math.sqrt(1 - z * z);
    return s <= 0 ? 0 : 1 - Math.exp(-z * w * s) * (Math.cos(wd * s) + ((z * w) / wd) * Math.sin(wd * s));
  };
  const clamp = (v) => Math.min(Math.max(v, 0), 1);
  const smooth = (p) => p * p * p * (10 - 15 * p + 6 * p * p);

  function frame() {
    const t = video.currentTime;
    KEYS.forEach((key, i) => {
      const shown = t < key.end ? lively(t - key.at) : 1 - crisp(t - key.end);
      const pressed = key.press == null ? 0 : crisp(t - key.press) - crisp(t - key.press - 0.22);
      const progress = key.from == null ? 0 : smooth(clamp((t - key.from) / (key.to - key.from)));
      const style = groups[i].style;
      style.opacity = clamp(shown);
      style.transform = `translateY(${(1 - shown) * 10}px)`;
      style.setProperty("--pressed", clamp(pressed));
      style.setProperty("--progress", progress);
    });
    requestAnimationFrame(frame);
  }
  requestAnimationFrame(frame);
})();
