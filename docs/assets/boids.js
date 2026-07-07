/**
 * Points — Boids Point Cloud Background
 * Thousands of points swarming with boids-like flocking behavior.
 * Mouse position acts as an attractor/repulsor.
 */
(function() {
  var canvas = document.getElementById('bg-canvas');
  if (!canvas) return;

  var ctx = canvas.getContext('2d');
  var POINTS = 1500;
  var particles = [];
  var mouseX = -1000, mouseY = -1000;
  var targetMX = 0.5, targetMY = 0.5;
  var time = 0;

  function resize() {
    canvas.width = window.innerWidth;
    canvas.height = window.innerHeight;
  }

  function createParticles() {
    particles = [];
    for (var i = 0; i < POINTS; i++) {
      var angle = Math.random() * Math.PI * 2;
      var radius = 50 + Math.random() * 400;
      particles.push({
        x: canvas.width / 2 + Math.cos(angle) * radius * (0.3 + Math.random() * 0.7),
        y: canvas.height / 2 + Math.sin(angle) * radius * (0.3 + Math.random() * 0.7),
        vx: (Math.random() - 0.5) * 0.8,
        vy: (Math.random() - 0.5) * 0.8,
        z: Math.random(),
        s: 0.3 + Math.random() * 1.2,
        life: Math.random()
      });
    }
  }

  function draw() {
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    time += 0.016;

    var w = canvas.width;
    var h = canvas.height;
    var cx = w / 2;
    var cy = h / 2;

    // Smooth mouse
    mouseX += (targetMX * w - mouseX) * 0.03;
    mouseY += (targetMY * h - mouseY) * 0.03;

    for (var i = 0; i < particles.length; i++) {
      var p = particles[i];

      // Boids-like: cohesion toward center
      var dx = cx - p.x;
      var dy = cy - p.y;
      var dist = Math.sqrt(dx * dx + dy * dy) || 1;
      var cohesionForce = 0.00015;
      p.vx += (dx / dist) * Math.min(dist * 0.02, 2) * cohesionForce;
      p.vy += (dy / dist) * Math.min(dist * 0.02, 2) * cohesionForce;

      // Mouse interaction: close = repel, far = attract
      var mdx = mouseX - p.x;
      var mdy = mouseY - p.y;
      var mdist = Math.sqrt(mdx * mdx + mdy * mdy) || 1;

      if (mdist < 200 && mdist > 0) {
        // Repel when near mouse
        var repelForce = (200 - mdist) / 200 * 0.03;
        p.vx -= (mdx / mdist) * repelForce;
        p.vy -= (mdy / mdist) * repelForce;
      } else if (mdist < 600 && mdist > 0 && mouseX > 0) {
        // Gentle attract at medium range
        var attractForce = 0.004;
        p.vx += (mdx / mdist) * attractForce;
        p.vy += (mdy / mdist) * attractForce;
      }

      // Perlin-like orbital motion based on z
      var orbitSpeed = 0.3 + p.z * 0.5;
      var orbitRadius = 0.8 + p.z * 1.5;
      p.vx += Math.cos(time * orbitSpeed + p.z * 12) * 0.008 * orbitRadius;
      p.vy += Math.sin(time * orbitSpeed * 0.7 + p.z * 10) * 0.008 * orbitRadius;

      // Damping
      p.vx *= 0.985;
      p.vy *= 0.985;

      // Speed limit
      var speed = Math.sqrt(p.vx * p.vx + p.vy * p.vy);
      if (speed > 3) {
        p.vx = (p.vx / speed) * 3;
        p.vy = (p.vy / speed) * 3;
      }

      p.x += p.vx;
      p.y += p.vy;

      // Wrap around edges
      if (p.x < -80) p.x = w + 80;
      if (p.x > w + 80) p.x = -80;
      if (p.y < -80) p.y = h + 80;
      if (p.y > h + 80) p.y = -80;

      // Only draw if in viewport
      if (p.x < -10 || p.x > w + 10 || p.y < -10 || p.y > h + 10) continue;

      // Depth-based rendering
      var depth = 0.4 + p.z * 0.6;
      var size = p.s * depth * 2;

      // Glow
      var alpha = 0.15 * depth;
      ctx.beginPath();
      ctx.arc(p.x, p.y, size * 4, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(255,255,255,' + alpha + ')';
      ctx.fill();

      // Core
      var coreAlpha = 0.25 + depth * 0.3;
      ctx.beginPath();
      ctx.arc(p.x, p.y, size, 0, Math.PI * 2);
      ctx.fillStyle = 'rgba(255,255,255,' + coreAlpha + ')';
      ctx.fill();

      // Bright center for closer points
      if (p.z > 0.7) {
        ctx.beginPath();
        ctx.arc(p.x, p.y, size * 0.4, 0, Math.PI * 2);
        ctx.fillStyle = 'rgba(255,255,255,' + (0.5 * depth) + ')';
        ctx.fill();
      }

      // Connection lines to nearby points
      for (var j = i + 1; j < Math.min(i + 8, particles.length); j++) {
        var q = particles[j];
        var ldx = p.x - q.x;
        var ldy = p.y - q.y;
        var ldist = Math.sqrt(ldx * ldx + ldy * ldy);
        if (ldist < 60 && ldist > 0) {
          ctx.beginPath();
          ctx.moveTo(p.x, p.y);
          ctx.lineTo(q.x, q.y);
          ctx.strokeStyle = 'rgba(255,255,255,' + (0.02 * (1 - ldist / 60)) + ')';
          ctx.lineWidth = 0.3;
          ctx.stroke();
        }
      }
    }

    requestAnimationFrame(draw);
  }

  document.addEventListener('mousemove', function(e) {
    targetMX = e.clientX / window.innerWidth;
    targetMY = e.clientY / window.innerHeight;
  });

  document.addEventListener('touchmove', function(e) {
    targetMX = e.touches[0].clientX / window.innerWidth;
    targetMY = e.touches[0].clientY / window.innerHeight;
  }, { passive: true });

  window.addEventListener('resize', function() {
    resize();
    createParticles();
  });

  resize();
  createParticles();
  draw();
})();
