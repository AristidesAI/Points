// Points — Interactive Point Cloud Background
// Renders a dynamic 3D point cloud that follows mouse movement
(function() {
  const canvas = document.getElementById('bg-canvas');
  if (!canvas) return;

  const ctx = canvas.getContext('2d');
  let points = [];
  const POINT_COUNT = 200;
  let mouseX = 0.5, mouseY = 0.5;
  let targetMouseX = 0.5, targetMouseY = 0.5;
  let time = 0;

  function resize() {
    canvas.width = window.innerWidth;
    canvas.height = window.innerHeight;
  }

  function createPoints() {
    points = [];
    for (let i = 0; i < POINT_COUNT; i++) {
      points.push({
        x: Math.random(),
        y: Math.random(),
        z: Math.random(),
        vx: 0, vy: 0,
        baseX: Math.random(),
        baseY: Math.random(),
        baseZ: Math.random(),
        size: 0.5 + Math.random() * 1.5,
        hue: 200 + Math.random() * 40, // blue-cyan range
        alpha: 0.3 + Math.random() * 0.5
      });
    }
  }

  function draw() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);

    // Smooth mouse follow
    mouseX += (targetMouseX - mouseX) * 0.05;
    mouseY += (targetMouseY - mouseY) * 0.05;
    time += 0.016;

    const w = canvas.width;
    const h = canvas.height;

    for (const p of points) {
      // Mouse influence: points drift toward mouse position
      const mx = (mouseX - 0.5) * 0.3;
      const my = (mouseY - 0.5) * 0.3;

      // Gentle orbital motion + mouse attraction
      const orbitX = Math.sin(time * 0.3 + p.baseZ * 6.28) * 0.02;
      const orbitY = Math.cos(time * 0.4 + p.baseZ * 6.28) * 0.02;

      p.vx += (mx + orbitX - (p.x - p.baseX)) * 0.003;
      p.vy += (my + orbitY - (p.y - p.baseY)) * 0.003;
      p.vx *= 0.95;
      p.vy *= 0.95;
      p.x += p.vx;
      p.y += p.vy;

      // Z-based parallax
      const depth = 0.5 + p.z * 0.5;
      const screenX = p.x * w;
      const screenY = p.y * h;
      const parallaxX = (mouseX - 0.5) * 40 * depth;
      const parallaxY = (mouseY - 0.5) * 40 * depth;

      const px = screenX + parallaxX;
      const py = screenY + parallaxY;

      // Only draw if in viewport with some margin
      if (px < -50 || px > w + 50 || py < -50 || py > h + 50) continue;

      const size = p.size * depth * 1.8;
      const alpha = p.alpha * depth * 0.6;

      // Glow circle
      const gradient = ctx.createRadialGradient(px, py, 0, px, py, size * 3);
      gradient.addColorStop(0, `hsla(${p.hue}, 70%, 60%, ${alpha})`);
      gradient.addColorStop(0.3, `hsla(${p.hue}, 60%, 50%, ${alpha * 0.6})`);
      gradient.addColorStop(1, 'transparent');

      ctx.beginPath();
      ctx.arc(px, py, size * 3, 0, Math.PI * 2);
      ctx.fillStyle = gradient;
      ctx.fill();

      // Bright core
      ctx.beginPath();
      ctx.arc(px, py, size * 0.6, 0, Math.PI * 2);
      ctx.fillStyle = `hsla(${p.hue}, 30%, 80%, ${alpha * 1.2})`;
      ctx.fill();
    }
    requestAnimationFrame(draw);
  }

  document.addEventListener('mousemove', (e) => {
    targetMouseX = e.clientX / window.innerWidth;
    targetMouseY = e.clientY / window.innerHeight;
  });

  // Touch support
  document.addEventListener('touchmove', (e) => {
    targetMouseX = e.touches[0].clientX / window.innerWidth;
    targetMouseY = e.touches[0].clientY / window.innerHeight;
  }, { passive: true });

  window.addEventListener('resize', resize);

  resize();
  createPoints();
  draw();
})();
