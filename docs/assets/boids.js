/**
 * Points — Boids Point Cloud Background
 * 2000 points with flocking behavior, mouse interaction, connection lines.
 */
(function() {
  var c = document.getElementById('bg');
  if (!c) return;
  var x = c.getContext('2d');
  var P = [], N = 2000, mx = -999, my = -999, tmx = 0.5, tmy = 0.5, T = 0;

  function R() { c.width = innerWidth; c.height = innerHeight; }

  for (var i = 0; i < N; i++) {
    var a = Math.random() * Math.PI * 2, r = 80 + Math.random() * 500;
    P.push({
      x: innerWidth/2 + Math.cos(a) * r * (0.3+Math.random()*0.7),
      y: innerHeight/2 + Math.sin(a) * r * (0.3+Math.random()*0.7),
      vx: 0, vy: 0, z: Math.random(), s: 0.2+Math.random()*1, l: Math.random()
    });
  }

  function D() {
    x.clearRect(0,0,c.width,c.height);
    T += 0.016;
    var w = c.width, h = c.height, cx = w/2, cy = h/2;
    mx += (tmx*w - mx)*0.03; my += (tmy*h - my)*0.03;

    for (var i = 0; i < P.length; i++) {
      var p = P[i];
      var dx = cx - p.x, dy = cy - p.y, d = Math.sqrt(dx*dx+dy*dy)||1;
      p.vx += (dx/d)*Math.min(d*0.02,2)*0.00015;
      p.vy += (dy/d)*Math.min(d*0.02,2)*0.00015;

      if (mx > 0) {
        var mdx = mx - p.x, mdy = my - p.y, md = Math.sqrt(mdx*mdx+mdy*mdy)||1;
        if (md < 200) { p.vx -= (mdx/md)*((200-md)/200)*0.03; p.vy -= (mdy/md)*((200-md)/200)*0.03; }
        else if (md < 600) { p.vx += (mdx/md)*0.004; p.vy += (mdy/md)*0.004; }
      }

      p.vx += Math.cos(T*(0.3+p.z*0.5)+p.z*12)*0.008*(0.8+p.z*1.5);
      p.vy += Math.sin(T*(0.21+p.z*0.35)+p.z*10)*0.008*(0.8+p.z*1.5);
      p.vx *= 0.985; p.vy *= 0.985;
      var s = Math.sqrt(p.vx*p.vx+p.vy*p.vy);
      if (s > 3) { p.vx = (p.vx/s)*3; p.vy = (p.vy/s)*3; }
      p.x += p.vx; p.y += p.vy;
      if (p.x<-80)p.x=w+80; if(p.x>w+80)p.x=-80;
      if(p.y<-80)p.y=h+80; if(p.y>h+80)p.y=-80;
      if (p.x<-10||p.x>w+10||p.y<-10||p.y>h+10) continue;

      var dp = 0.4+p.z*0.6, sz = p.s*dp*2;
      x.beginPath(); x.arc(p.x,p.y,sz*4,0,Math.PI*2);
      x.fillStyle = 'rgba(255,255,255,'+(0.12*dp)+')'; x.fill();
      x.beginPath(); x.arc(p.x,p.y,sz,0,Math.PI*2);
      x.fillStyle = 'rgba(255,255,255,'+(0.22+dp*0.28)+')'; x.fill();
      if (p.z>0.7) { x.beginPath(); x.arc(p.x,p.y,sz*0.4,0,Math.PI*2); x.fillStyle='rgba(255,255,255,'+(0.45*dp)+')'; x.fill(); }

      for (var j=i+1;j<Math.min(i+8,P.length);j++) {
        var q=P[j], ldx=p.x-q.x, ldy=p.y-q.y, ld=Math.sqrt(ldx*ldx+ldy*ldy);
        if (ld<55&&ld>0){x.beginPath();x.moveTo(p.x,p.y);x.lineTo(q.x,q.y);x.strokeStyle='rgba(255,255,255,'+(0.015*(1-ld/55))+')';x.lineWidth=0.3;x.stroke();}
      }
    }
    requestAnimationFrame(D);
  }

  document.addEventListener('mousemove',function(e){tmx=e.clientX/innerWidth;tmy=e.clientY/innerHeight;});
  document.addEventListener('touchmove',function(e){tmx=e.touches[0].clientX/innerWidth;tmy=e.touches[0].clientY/innerHeight;},{passive:true});
  window.addEventListener('resize',function(){R();for(var i=0;i<P.length;i++){P[i].x=innerWidth/2;P[i].y=innerHeight/2;}});
  R(); D();
})();
