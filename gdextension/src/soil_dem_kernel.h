#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
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
	/// 只设置材料参数和粒径，不生成粒子（用于从脱落物质生成粒子）。
	void setup_material(double radius, double density, double cohesion,
			double friction, double stiffness, double damping);
	void clear_particles();
	/// 按质量在 center 附近生成粒子，返回实际粒子数。
	int spawn_from_mass(double mass, const Vector3 &center, double spread,
			int seed);
	void set_bounds(const Vector3 &min, const Vector3 &max);
	void set_tool(double x, double speed);
	/// 球心重力：g(r)=g0·(R/(R+alt))²，方向指向球心。默认关闭（平面 -Y）。
	void set_spherical_gravity(double planet_radius, double surface_gravity);
	void set_planar_gravity(double gravity);
	void step(double dt);

	PackedVector3Array get_positions() const;
	PackedVector3Array get_velocities() const;
	/// 移除指定下标的粒子（用于把静止粒子合并回物质场）。
	void remove_particles(const PackedInt32Array &indices);
	double get_total_mass() const;
	double get_particle_mass() const;
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

	bool spherical_gravity_ = false;
	float planet_radius_ = 3978.87f;
	float surface_gravity_ = 9.81f;

	float tool_x_ = 0.151f;
	float tool_speed_ = 0.05f;
	float tool_force_ = 0.0f;
	int steps_ = 0;
};

} // namespace godot
