#pragma once

// The bit writer and the DotNetVar encoders, ported from dot_net_writer.gd and dot_net_var.gd bit
// for bit. Any change here is a protocol change; netcode_demo's [native] section compares both.

#include <godot_cpp/variant/quaternion.hpp>
#include <godot_cpp/variant/vector3.hpp>

#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

namespace dotnet {

constexpr int64_t MAX_BYTES = 1 << 22;
constexpr double PI_D = 3.14159265358979323846;

// DotNetVar.Type, in declaration order.
enum VarType {
	T_BOOL,
	T_UINT,
	T_INT,
	T_VARINT,
	T_FLOAT,
	T_FLOAT_RANGE,
	T_VECTOR3_POSITION,
	T_VECTOR3_VELOCITY,
	T_VECTOR3_RANGE,
	T_DIRECTION,
	T_QUATERNION,
	T_ANGLE,
	T_STRING,
	T_BYTES,
	T_CUSTOM,
};

inline int64_t mask_of(int bits) {
	return bits >= 64 ? int64_t(-1) : int64_t((uint64_t(1) << bits) - 1);
}

// GDScript's int(float): a truncating conversion, as the engine compiles it.
inline int64_t to_int(double v) {
	return int64_t(v);
}

inline double clampd(double v, double lo, double hi) {
	// Godot's CLAMP: a NaN passes through, as it does in GDScript.
	return v < lo ? lo : (v > hi ? hi : v);
}

inline double fposmod(double x, double y) {
	double value = std::fmod(x, y);
	if ((value < 0 && y > 0) || (value > 0 && y < 0)) {
		value += y;
	}
	value += 0.0;
	return value;
}

class BitWriter {
public:
	std::vector<uint8_t> bytes;
	int64_t bit_pos = 0;
	bool overflowed = false;

	void reset() {
		bytes.clear();
		bit_pos = 0;
		overflowed = false;
	}

	int64_t bit_length() const { return bit_pos; }
	int64_t byte_length() const { return (bit_pos + 7) >> 3; }

	void write_bits(int64_t value, int bits) {
		if (bits <= 0 || bits > 64) {
			return;
		}
		uint64_t v = bits >= 64 ? uint64_t(value) : uint64_t(value) & ((uint64_t(1) << bits) - 1);
		int remaining = bits;
		while (remaining > 0) {
			int64_t byte_index = bit_pos >> 3;
			int bit_offset = int(bit_pos & 7);
			int take = 8 - bit_offset < remaining ? 8 - bit_offset : remaining;
			if (byte_index >= int64_t(bytes.size())) {
				if (int64_t(bytes.size()) >= MAX_BYTES) {
					overflowed = true;
					return;
				}
				bytes.push_back(0);
			}
			bytes[byte_index] |= uint8_t((v & ((uint64_t(1) << take) - 1)) << bit_offset);
			v >>= take;
			bit_pos += take;
			remaining -= take;
		}
	}

	void write_bool(bool b) { write_bits(b ? 1 : 0, 1); }
	void write_uint(int64_t v, int bits) { write_bits(v, bits); }
	void write_int(int64_t v, int bits) { write_bits(v & mask_of(bits), bits); }

	void write_varint(int64_t value) {
		uint64_t v = value < 0 ? 0 : uint64_t(value);
		while (true) {
			int64_t group = int64_t(v & 0x7F);
			v >>= 7;
			if (v == 0) {
				write_bits(group, 8);
				return;
			}
			write_bits(group | 0x80, 8);
		}
	}

	void write_svarint(int64_t value) {
		write_varint(int64_t((uint64_t(value) << 1) ^ uint64_t(value >> 63)));
	}

	void write_float_range(double value, double min_value, double max_value, int bits) {
		if (max_value <= min_value) {
			write_bits(0, bits);
			return;
		}
		double span = max_value - min_value;
		double normalised = clampd((value - min_value) / span, 0.0, 1.0);
		write_bits(to_int(std::round(normalised * double(mask_of(bits)))), bits);
	}

	void write_angle(double degrees, int bits) {
		double wrapped = fposmod(degrees, 360.0);
		int64_t steps = int64_t((uint64_t(1) << (bits & 63)) - 1);
		write_bits(to_int(std::round(wrapped / 360.0 * double(steps))) & mask_of(bits), bits);
	}

	void write_float32(double value) {
		float f = float(value);
		uint32_t u;
		std::memcpy(&u, &f, 4);
		for (int i = 0; i < 4; i++) {
			write_bits((u >> (8 * i)) & 0xFF, 8);
		}
	}

	void write_vector3_range(const godot::Vector3 &v, double min_value, double max_value, int bits) {
		write_float_range(v.x, min_value, max_value, bits);
		write_float_range(v.y, min_value, max_value, bits);
		write_float_range(v.z, min_value, max_value, bits);
	}

	void write_direction(const godot::Vector3 &direction, int bits) {
		godot::Vector3 d = direction.normalized();
		if (!d.is_finite() || double(d.length_squared()) < 0.5) {
			d = godot::Vector3(0, 1, 0);
		}
		write_float_range(std::acos(clampd(d.y, -1.0, 1.0)), 0.0, PI_D, bits);
		write_float_range(std::atan2(double(d.z), double(d.x)), -PI_D, PI_D, bits);
	}

	void write_quaternion(const godot::Quaternion &rotation, int bits) {
		godot::Quaternion q = rotation.normalized();
		double c[4] = { q.x, q.y, q.z, q.w };
		int largest = 0;
		double largest_value = std::fabs(c[0]);
		for (int i = 1; i < 4; i++) {
			double magnitude = std::fabs(c[i]);
			if (magnitude > largest_value) {
				largest_value = magnitude;
				largest = i;
			}
		}
		double sign_flip = c[largest] < 0.0 ? -1.0 : 1.0;
		write_bits(largest, 2);
		const double LIMIT = 0.7071067811865476;
		for (int i = 0; i < 4; i++) {
			if (i == largest) {
				continue;
			}
			write_float_range(clampd(c[i] * sign_flip, -LIMIT, LIMIT), -LIMIT, LIMIT, bits);
		}
	}

	void align() {
		int remainder = int(bit_pos & 7);
		if (remainder != 0) {
			write_bits(0, 8 - remainder);
		}
	}

	void write_bytes(const uint8_t *data, int64_t size) {
		write_varint(size);
		align();
		if (int64_t(bytes.size()) + size > MAX_BYTES) {
			overflowed = true;
			return;
		}
		bytes.insert(bytes.end(), data, data + size);
		bit_pos = int64_t(bytes.size()) << 3;
	}

	// [bits] bits of [data], written from its bit [from_bit], laid in here. A copy when both sit at
	// the same bit of a byte, else shifted; the result is the same bits either way.
	void write_run(const uint8_t *data, int64_t from_bit, int64_t bits) {
		for (int64_t done = 0; done < bits;) {
			int64_t at = from_bit + done;
			int take = int(bits - done < 56 ? bits - done : 56);
			uint64_t chunk = 0;
			int64_t first = at >> 3;
			int shift = int(at & 7);
			int need = (shift + take + 7) >> 3;
			for (int k = 0; k < need; k++) {
				chunk |= uint64_t(data[first + k]) << (8 * k);
			}
			write_bits(int64_t(chunk >> shift), take);
			done += take;
		}
	}
};

// The UTF-8 bytes write_string sends for [utf8], cut as it cuts them.
inline int64_t truncated_string_size(const uint8_t *utf8, int64_t size, int64_t max_bytes = 1024) {
	if (size <= max_bytes) {
		return size;
	}
	int64_t n = max_bytes;
	while (n > 0 && (utf8[n - 1] & 0xC0) == 0x80) {
		n--;
	}
	return n;
}

} // namespace dotnet
