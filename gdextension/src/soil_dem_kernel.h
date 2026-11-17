#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_vector3_array.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <vector>

namespace godot {

/// 土颗粒 DEM 内核。这是 GDScript 原型的原生移植：
/// 同样的软接触 + Coulomb 摩擦 + 黏聚 + 推板，换取 C++ 的迭代速度。
class SoilDEMKernel : public RefCounted {
	GDCLASS(SoilDEMKernel, RefCounted)

public:
	SoilDEMKernel() = default;
	~SoilDEMKernel() override = default;

	void configure(int count, double radius, double density, double cohesion,
			double friction, double stiffness, double damping, int seed);
	void set_bounds(const Vector3 &min, const Vector3 &max);
	void set_tool(double x, double speed);
	void step(double dt);

	PackedVector3Array get_positions() const;
	double get_total_mass() const;
	double get_tool_force() const;
	int get_particle_count() const;
	int get_step_count() const;

protected:
	static void _bind_methods();

private:
	void _populate();
	void _contact(int i, int j, std::vector<Vector3> &forces, float dt);
	void _clamp_to_box(int i);

	std::vector<Vector3> positions_;
	std::vector<Vector3> velocities_;

	int count_ = 1000;
	float radius_ = 0.01f;
	float density_ = 1600.0f;
	float mass_ = 0.0f;
	float cohesion_ = 0.0f;
	float friction_ = 0.55f;
	float stiffness_ = 3000.0f;
	float damping_ratio_ = 0.25f;
	int seed_ = 42;

	Vector3 bounds_min_ = Vector3(-0.15f, 0.0f, -0.15f);
	Vector3 bounds_max_ = Vector3(0.15f, 0.2f, 0.15f);

	float tool_x_ = 0.151f;
	float tool_speed_ = 0.05f;
	float tool_force_ = 0.0f;
	int steps_ = 0;
};

} // namespace godot
