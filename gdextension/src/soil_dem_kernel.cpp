#include "soil_dem_kernel.h"

#include <godot_cpp/core/class_db.hpp>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <random>
#include <unordered_map>
#include <vector>

using namespace godot;

namespace {

constexpr float PI_F = 3.14159265358979323846f;
constexpr float GRAVITY = -9.81f;

struct CellKey {
	int x = 0;
	int y = 0;
	int z = 0;
	bool operator==(const CellKey &other) const {
		return x == other.x && y == other.y && z == other.z;
	}
};

struct CellHash {
	size_t operator()(const CellKey &k) const {
		return (static_cast<size_t>(k.x) * 73856093u)
				^ (static_cast<size_t>(k.y) * 19349663u)
				^ (static_cast<size_t>(k.z) * 83492791u);
	}
};

} // namespace

void SoilDEMKernel::configure(int count, double radius, double density,
		double cohesion, double friction, double stiffness, double damping,
		int seed) {
	count_ = std::max(count, 1);
	radius_ = static_cast<float>(radius);
	density_ = static_cast<float>(density);
	cohesion_ = static_cast<float>(cohesion);
	friction_ = static_cast<float>(friction);
	stiffness_ = static_cast<float>(stiffness);
	damping_ratio_ = static_cast<float>(damping);
	seed_ = seed;
	mass_ = density_ * (4.0f / 3.0f) * PI_F * radius_ * radius_ * radius_;
	steps_ = 0;
	tool_force_ = 0.0f;
	_populate();
}

void SoilDEMKernel::setup_material(double radius, double density,
		double cohesion, double friction, double stiffness, double damping) {
	radius_ = static_cast<float>(radius);
	density_ = static_cast<float>(density);
	cohesion_ = static_cast<float>(cohesion);
	friction_ = static_cast<float>(friction);
	stiffness_ = static_cast<float>(stiffness);
	damping_ratio_ = static_cast<float>(damping);
	mass_ = density_ * (4.0f / 3.0f) * PI_F * radius_ * radius_ * radius_;
	clear_particles();
}

void SoilDEMKernel::clear_particles() {
	positions_.clear();
	velocities_.clear();
	steps_ = 0;
	tool_force_ = 0.0f;
}

int SoilDEMKernel::spawn_from_mass(double mass, const Vector3 &center,
		double spread, int seed) {
	if (mass <= 0.0 || mass_ <= 0.0f) {
		return 0;
	}
	const int count = std::max(1, static_cast<int>(std::round(mass / mass_)));
	std::mt19937 rng(static_cast<uint32_t>(seed));
	std::uniform_real_distribution<float> uniform(0.0f, 1.0f);
	const float max_spread = static_cast<float>(std::max(spread, 0.0));
	positions_.reserve(positions_.size() + count);
	velocities_.reserve(velocities_.size() + count);
	for (int i = 0; i < count; ++i) {
		Vector3 offset;
		if (max_spread > 0.0f) {
			// 球内均匀采样
			const float u = uniform(rng);
			const float theta = uniform(rng) * 2.0f * PI_F;
			const float z = 2.0f * uniform(rng) - 1.0f;
			const float r_xy = std::sqrt(std::max(0.0f, 1.0f - z * z));
			const float r = max_spread * std::cbrt(u);
			offset = Vector3(r * r_xy * std::cos(theta),
					r * r_xy * std::sin(theta), r * z);
		}
		positions_.push_back(center + offset);
		velocities_.push_back(Vector3());
	}
	return count;
}

void SoilDEMKernel::_populate() {
	positions_.clear();
	velocities_.clear();
	positions_.reserve(count_);
	velocities_.reserve(count_);

	std::mt19937 rng(static_cast<uint32_t>(seed_));
	std::uniform_real_distribution<float> jitter(-0.08f, 0.08f);
	std::uniform_real_distribution<float> uniform(0.0f, 1.0f);

	const float spacing = radius_ * 2.05f;
	const Vector3 size = bounds_max_ - bounds_min_;
	const int nx = std::max(1, static_cast<int>(size.x / spacing));
	const int ny = std::max(1, static_cast<int>(size.y / spacing));
	const int nz = std::max(1, static_cast<int>(size.z / spacing));

	int placed = 0;
	for (int ix = 0; ix < nx && placed < count_; ++ix) {
		for (int iy = 0; iy < ny && placed < count_; ++iy) {
			for (int iz = 0; iz < nz && placed < count_; ++iz) {
				Vector3 p = bounds_min_ + Vector3(
						(ix + 0.5f) * spacing,
						(iy + 0.5f) * spacing,
						(iz + 0.5f) * spacing);
				p.x += jitter(rng) * radius_;
				p.y += jitter(rng) * radius_;
				p.z += jitter(rng) * radius_;
				positions_.push_back(p);
				velocities_.push_back(Vector3());
				++placed;
			}
		}
	}
	while (placed < count_) {
		Vector3 p(
				bounds_min_.x + uniform(rng) * size.x,
				bounds_min_.y + uniform(rng) * size.y,
				bounds_min_.z + uniform(rng) * size.z);
		positions_.push_back(p);
		velocities_.push_back(Vector3());
		++placed;
	}
}

void SoilDEMKernel::set_bounds(const Vector3 &min, const Vector3 &max) {
	bounds_min_ = min;
	bounds_max_ = max;
}

void SoilDEMKernel::set_tool(double x, double speed) {
	tool_x_ = static_cast<float>(x);
	tool_speed_ = static_cast<float>(speed);
}

void SoilDEMKernel::step(double dt_in) {
	if (positions_.empty()) {
		return;
	}
	const float dt = static_cast<float>(dt_in);
	const int n = static_cast<int>(positions_.size());
	std::vector<Vector3> forces(n, Vector3(0.0f, GRAVITY * mass_, 0.0f));

	const float cell = radius_ * 2.0f + 0.002f;
	std::unordered_map<CellKey, std::vector<int>, CellHash> buckets;
	buckets.reserve(static_cast<size_t>(n) * 2);

	for (int i = 0; i < n; ++i) {
		const Vector3 &p = positions_[i];
		CellKey key{
			static_cast<int>(std::floor(p.x / cell)),
			static_cast<int>(std::floor(p.y / cell)),
			static_cast<int>(std::floor(p.z / cell)),
		};
		buckets[key].push_back(i);
	}

	for (int i = 0; i < n; ++i) {
		const Vector3 &p = positions_[i];
		const CellKey key{
			static_cast<int>(std::floor(p.x / cell)),
			static_cast<int>(std::floor(p.y / cell)),
			static_cast<int>(std::floor(p.z / cell)),
		};
		for (int dx = -1; dx <= 1; ++dx) {
			for (int dy = -1; dy <= 1; ++dy) {
				for (int dz = -1; dz <= 1; ++dz) {
					const CellKey neighbor{key.x + dx, key.y + dy, key.z + dz};
					auto it = buckets.find(neighbor);
					if (it == buckets.end()) {
						continue;
					}
					for (int j : it->second) {
						if (j <= i) {
							continue;
						}
						_contact(i, j, forces, dt);
					}
				}
			}
		}
	}

	// 推板（沿 -X 方向推进）
	tool_force_ = 0.0f;
	const float damping_coeff = 2.0f * damping_ratio_
			* std::sqrt(stiffness_ * mass_);
	for (int i = 0; i < n; ++i) {
		const Vector3 &p = positions_[i];
		if (p.x + radius_ <= tool_x_) {
			continue;
		}
		const float overlap = p.x + radius_ - tool_x_;
		const float vx = velocities_[i].x + tool_speed_;
		float force = stiffness_ * overlap - damping_coeff * vx;
		force = std::max(force, 0.0f);
		forces[i].x -= force;
		tool_force_ += force;
	}

	const float damp = std::exp(-0.8f * dt);
	for (int i = 0; i < n; ++i) {
		Vector3 &v = velocities_[i];
		v += forces[i] * (dt / mass_);
		v *= damp;
		positions_[i] += v * dt;
		_clamp_to_box(i);
		if (velocities_[i].length_squared() < 4.0e-6f) {
			velocities_[i] = Vector3();
		}
	}

	tool_x_ = std::max(tool_x_ - tool_speed_ * dt, bounds_min_.x + 0.02f);
	++steps_;
}

void SoilDEMKernel::_contact(int i, int j, std::vector<Vector3> &forces,
		float dt) {
	const Vector3 delta = positions_[j] - positions_[i];
	const float dist = delta.length();
	const float radius_sum = radius_ * 2.0f;
	if (dist >= radius_sum || dist < 1.0e-6f) {
		return;
	}
	const Vector3 normal = delta / dist;
	const float overlap = radius_sum - dist;
	const Vector3 relative = velocities_[j] - velocities_[i];
	const float vn = relative.dot(normal);
	const float m_eff = mass_ * 0.5f;
	const float damping = 2.0f * damping_ratio_
			* std::sqrt(stiffness_ * m_eff);

	const float spring = stiffness_ * overlap - damping * vn;
	const float repulsion = std::max(spring, 0.0f);
	const float area = PI_F * radius_ * radius_;
	const float cohesion_force = cohesion_ * area;

	const Vector3 tangent = relative - normal * vn;
	const float tangent_len = tangent.length();
	float friction_force = 0.0f;
	if (tangent_len > 1.0e-6f) {
		friction_force = std::min(friction_ * repulsion,
				tangent_len * m_eff / dt);
	}

	// 作用在 i 上的力：法向排斥（-normal*repulsion）+ 黏聚（+normal*cohesion）
	// + 切向拖拽（+tangent*friction）。j 受力相反。
	Vector3 force_on_i = normal * (cohesion_force - repulsion);
	if (tangent_len > 1.0e-6f) {
		force_on_i += tangent / tangent_len * friction_force;
	}
	forces[i] += force_on_i;
	forces[j] -= force_on_i;
}

void SoilDEMKernel::_clamp_to_box(int i) {
	Vector3 &p = positions_[i];
	Vector3 &v = velocities_[i];
	if (p.x < bounds_min_.x + radius_) {
		p.x = bounds_min_.x + radius_;
		v.x = std::max(v.x, 0.0f);
	}
	if (p.x > bounds_max_.x - radius_) {
		p.x = bounds_max_.x - radius_;
		v.x = std::min(v.x, 0.0f);
	}
	if (p.y < bounds_min_.y + radius_) {
		p.y = bounds_min_.y + radius_;
		v.y = std::max(v.y, 0.0f);
	}
	if (p.y > bounds_max_.y - radius_) {
		p.y = bounds_max_.y - radius_;
		v.y = std::min(v.y, 0.0f);
	}
	if (p.z < bounds_min_.z + radius_) {
		p.z = bounds_min_.z + radius_;
		v.z = std::max(v.z, 0.0f);
	}
	if (p.z > bounds_max_.z - radius_) {
		p.z = bounds_max_.z - radius_;
		v.z = std::min(v.z, 0.0f);
	}
}

PackedVector3Array SoilDEMKernel::get_positions() const {
	PackedVector3Array out;
	const int n = static_cast<int>(positions_.size());
	out.resize(n);
	for (int i = 0; i < n; ++i) {
		out[i] = positions_[i];
	}
	return out;
}

double SoilDEMKernel::get_total_mass() const {
	return static_cast<double>(mass_) * static_cast<double>(positions_.size());
}

double SoilDEMKernel::get_particle_mass() const {
	return static_cast<double>(mass_);
}

double SoilDEMKernel::get_tool_force() const {
	return static_cast<double>(tool_force_);
}

int SoilDEMKernel::get_particle_count() const {
	return static_cast<int>(positions_.size());
}

int SoilDEMKernel::get_step_count() const {
	return steps_;
}

void SoilDEMKernel::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "count", "radius", "density",
								 "cohesion", "friction", "stiffness", "damping",
								 "seed"),
			&SoilDEMKernel::configure);
	ClassDB::bind_method(D_METHOD("setup_material", "radius", "density",
								 "cohesion", "friction", "stiffness",
								 "damping"),
			&SoilDEMKernel::setup_material);
	ClassDB::bind_method(D_METHOD("clear_particles"),
			&SoilDEMKernel::clear_particles);
	ClassDB::bind_method(D_METHOD("spawn_from_mass", "mass", "center",
								 "spread", "seed"),
			&SoilDEMKernel::spawn_from_mass);
	ClassDB::bind_method(D_METHOD("set_bounds", "min", "max"),
			&SoilDEMKernel::set_bounds);
	ClassDB::bind_method(D_METHOD("set_tool", "x", "speed"),
			&SoilDEMKernel::set_tool);
	ClassDB::bind_method(D_METHOD("step", "dt"), &SoilDEMKernel::step);
	ClassDB::bind_method(D_METHOD("get_positions"),
			&SoilDEMKernel::get_positions);
	ClassDB::bind_method(D_METHOD("get_total_mass"),
			&SoilDEMKernel::get_total_mass);
	ClassDB::bind_method(D_METHOD("get_particle_mass"),
			&SoilDEMKernel::get_particle_mass);
	ClassDB::bind_method(D_METHOD("get_tool_force"),
			&SoilDEMKernel::get_tool_force);
	ClassDB::bind_method(D_METHOD("get_particle_count"),
			&SoilDEMKernel::get_particle_count);
	ClassDB::bind_method(D_METHOD("get_step_count"),
			&SoilDEMKernel::get_step_count);
}
