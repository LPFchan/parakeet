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

  // When each one shows, is pressed (or moves, on a spring of perceptual
  // duration `dur`, as the pointer and the pinch did), and goes, in the video's seconds.
  const KEYS = [
    { at: 3.3, press: 3.9, end: 4.75 },            // ⇧⌘1
    { at: 4.95, from: 5.25, dur: 0.5, end: 6.3 },  // the pinch
    { at: 6.45, from: 6.93, dur: 0.55, end: 8.9 }, // the drag
    { at: 9.75, press: 10.29, end: 11.2 },         // esc
  ];

  // A critically damped spring, `s` seconds in; the app's own is crisp
  // (perceptualDuration 0.34). A livelier one with a little bounce for things arriving.
  const spring = (s, dur) => {
    const w = (2 * Math.PI) / dur;
    return s <= 0 ? 0 : 1 - (1 + w * s) * Math.exp(-w * s);
  };
  const crisp = (s) => spring(s, 0.34);
  const lively = (s) => {
    const w = (2 * Math.PI) / 0.42, z = 0.62, wd = w * Math.sqrt(1 - z * z);
    return s <= 0 ? 0 : 1 - Math.exp(-z * w * s) * (Math.cos(wd * s) + ((z * w) / wd) * Math.sin(wd * s));
  };
  const clamp = (v) => Math.min(Math.max(v, 0), 1);

  function frame() {
    const t = video.currentTime;
    KEYS.forEach((key, i) => {
      const shown = t < key.end ? lively(t - key.at) : 1 - crisp(t - key.end);
      const pressed = key.press == null ? 0 : crisp(t - key.press) - crisp(t - key.press - 0.22);
      const progress = key.from == null ? 0 : spring(t - key.from, key.dur);
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
