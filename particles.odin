package main

import "core:math"
import "core:math/rand"

Particle :: struct {
	pos:      vec2,
	vel:      vec2,
	color:    Color,
	size:     f32,
	lifetime: f32, // total lifetime in seconds
	age:      f32, // current age in seconds (starts at 0)
	fade:     bool,
	shrink:   bool,
}

ParticleSystem :: struct {
	particles: [dynamic]Particle,
}

EmitConfig :: struct {
	color:        Color, // base color
	speed_min:    f32,   // min initial speed
	speed_max:    f32,   // max initial speed
	size_min:     f32,   // min particle size
	size_max:     f32,   // max particle size
	lifetime_min: f32,   // min lifetime in seconds
	lifetime_max: f32,   // max lifetime in seconds
	spread:       f32,   // angle spread in radians (TAU = all directions)
	direction:    f32,   // center angle in radians (0 = right, TAU/4 = down)
	fade:         bool,  // if true, alpha fades to 0 over lifetime
	shrink:       bool,  // if true, size shrinks to 0 over lifetime
}

particles_init :: proc() -> ParticleSystem {
	return ParticleSystem{
		particles = make([dynamic]Particle),
	}
}

particles_destroy :: proc(ps: ^ParticleSystem) {
	delete(ps.particles)
}

particles_emit :: proc(ps: ^ParticleSystem, pos: vec2, count: int, config: EmitConfig) {
	for _ in 0 ..< count {
		speed    := config.speed_min + rand.float32() * (config.speed_max - config.speed_min)
		angle    := config.direction - config.spread * 0.5 + rand.float32() * config.spread
		size     := config.size_min + rand.float32() * (config.size_max - config.size_min)
		lifetime := config.lifetime_min + rand.float32() * (config.lifetime_max - config.lifetime_min)
		vel      := vec2{math.cos(angle), math.sin(angle)} * speed
		append(&ps.particles, Particle{
			pos      = pos,
			vel      = vel,
			color    = config.color,
			size     = size,
			lifetime = lifetime,
			age      = 0,
			fade     = config.fade,
			shrink   = config.shrink,
		})
	}
}

particles_update :: proc(ps: ^ParticleSystem, dt: f32) {
	#reverse for _, i in ps.particles {
		ps.particles[i].pos += ps.particles[i].vel * dt
		ps.particles[i].age += dt
		if ps.particles[i].age >= ps.particles[i].lifetime {
			unordered_remove(&ps.particles, i)
		}
	}
}

particles_draw :: proc(ps: ^ParticleSystem, r: ^Renderer) {
	for p in ps.particles {
		t    := p.age / p.lifetime
		c    := p.color
		size := p.size

		if p.fade   { c.a  *= (1.0 - t) }
		if p.shrink { size  *= (1.0 - t) }

		half := vec2{size, size} * 0.5
		draw_rect(r, Rect{p.pos - half, p.pos + half}, c)
	}
}
