#include "dot_net_native_core.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>
#include <godot_cpp/variant/char_string.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <algorithm>
#include <chrono>

using namespace godot;
using namespace dotnet;

namespace {

// Wire constants, as dot_net_manager.gd and dot_net_registry.gd define them.
constexpr int ID_BITS = 24;
constexpr int MAX_PARTS = 16;
constexpr int TRAILER_BITS = 8;
constexpr int COUNT_BYTE = 32 >> 3;
constexpr int TAIL_MARK = 0x0F;
constexpr int LEAD_FIELD_BITS = 12;
constexpr int LEAD_BITS = 2 * LEAD_FIELD_BITS;
constexpr int AUD_OWNER = 1;
constexpr int AUD_OBSERVERS = 2;

enum EncKind : uint8_t {
	E_NATIVE,
	E_BYTES,
	E_PRE,
};

int64_t usec_now() {
	return std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

Val make_val(const Variant &v) {
	Val out;
	out.vt = uint8_t(v.get_type());
	switch (v.get_type()) {
		case Variant::NIL:
			break;
		case Variant::BOOL:
			out.u.b = bool(v);
			break;
		case Variant::INT:
			out.u.i = int64_t(v);
			break;
		case Variant::FLOAT:
			out.u.f = double(v);
			break;
		case Variant::VECTOR2: {
			Vector2 x = v;
			out.u.v[0] = x.x;
			out.u.v[1] = x.y;
		} break;
		case Variant::VECTOR3: {
			Vector3 x = v;
			out.u.v[0] = x.x;
			out.u.v[1] = x.y;
			out.u.v[2] = x.z;
		} break;
		case Variant::QUATERNION: {
			Quaternion x = v;
			out.u.v[0] = x.x;
			out.u.v[1] = x.y;
			out.u.v[2] = x.z;
			out.u.v[3] = x.w;
		} break;
		default:
			out.ext = std::make_shared<const Variant>(v);
			break;
	}
	return out;
}

Variant to_variant(const Val &a) {
	switch (a.vt) {
		case Variant::NIL:
			return Variant();
		case Variant::BOOL:
			return a.u.b;
		case Variant::INT:
			return a.u.i;
		case Variant::FLOAT:
			return a.u.f;
		case Variant::VECTOR2:
			return Vector2(a.u.v[0], a.u.v[1]);
		case Variant::VECTOR3:
			return Vector3(a.u.v[0], a.u.v[1], a.u.v[2]);
		case Variant::QUATERNION:
			return Quaternion(a.u.v[0], a.u.v[1], a.u.v[2], a.u.v[3]);
		default:
			return a.ext ? *a.ext : Variant();
	}
}

// DotNetVar._values_equal: the same type, and equal.
bool val_equal(const Val &a, const Val &b) {
	if (a.vt != b.vt) {
		return false;
	}
	switch (a.vt) {
		case Variant::NIL:
			return true;
		case Variant::BOOL:
			return a.u.b == b.u.b;
		case Variant::INT:
			return a.u.i == b.u.i;
		case Variant::FLOAT:
			return a.u.f == b.u.f;
		case Variant::VECTOR2:
			return a.u.v[0] == b.u.v[0] && a.u.v[1] == b.u.v[1];
		case Variant::VECTOR3:
			return a.u.v[0] == b.u.v[0] && a.u.v[1] == b.u.v[1] && a.u.v[2] == b.u.v[2];
		case Variant::QUATERNION:
			return a.u.v[0] == b.u.v[0] && a.u.v[1] == b.u.v[1] && a.u.v[2] == b.u.v[2] && a.u.v[3] == b.u.v[3];
		default:
			if (a.ext == b.ext) {
				return true;
			}
			if (!a.ext || !b.ext) {
				return false;
			}
			return *a.ext == *b.ext;
	}
}

// DotNetVar.differs.
bool differs(const Decl &d, const Val &old, const Val &cur) {
	if (d.epsilon <= 0.0) {
		return !val_equal(old, cur);
	}
	if (old.vt == Variant::FLOAT && cur.vt == Variant::FLOAT) {
		return std::fabs(old.u.f - cur.u.f) > d.epsilon;
	}
	if (old.vt == Variant::VECTOR3 && cur.vt == Variant::VECTOR3) {
		Vector3 a(old.u.v[0], old.u.v[1], old.u.v[2]);
		Vector3 b(cur.u.v[0], cur.u.v[1], cur.u.v[2]);
		return double(a.distance_to(b)) > d.epsilon;
	}
	if (old.vt == Variant::VECTOR2 && cur.vt == Variant::VECTOR2) {
		Vector2 a(old.u.v[0], old.u.v[1]);
		Vector2 b(cur.u.v[0], cur.u.v[1]);
		return double(a.distance_to(b)) > d.epsilon;
	}
	if (old.vt == Variant::INT && cur.vt == Variant::INT) {
		int64_t diff = int64_t(uint64_t(old.u.i) - uint64_t(cur.u.i));
		return (diff < 0 ? -diff : diff) > to_int(d.epsilon);
	}
	return !val_equal(old, cur);
}

bool may_align(int type) {
	return type == T_STRING || type == T_BYTES || type == T_CUSTOM;
}

Decl decl_from(const PackedFloat64Array &s) {
	Decl d;
	if (s.size() < 14) {
		return d;
	}
	d.type = int(s[0]);
	d.audience = int(s[1]);
	d.max_rate = s[2];
	d.epsilon = s[3];
	d.on_spawn_only = s[4] != 0.0;
	d.bit_width = int(s[5]);
	d.min_value = s[6];
	d.max_value = s[7];
	d.extent = s[8];
	d.position_bits = int(s[9]);
	d.max_speed = s[10];
	d.velocity_bits = int(s[11]);
	d.rotation_bits = int(s[12]);
	d.slot = int(s[13]);
	return d;
}

// The value as DotNetVar.write converts it, or false for one only GDScript can convert.
bool native_enc(const Decl &d, const Variant &v, Enc &e) {
	Variant::Type vt = v.get_type();
	e.kind = E_NATIVE;
	switch (d.type) {
		case T_BOOL:
			if (vt == Variant::BOOL) {
				e.i = bool(v) ? 1 : 0;
			} else if (vt == Variant::INT) {
				e.i = int64_t(v) != 0 ? 1 : 0;
			} else if (vt == Variant::FLOAT) {
				e.i = double(v) != 0.0 ? 1 : 0;
			} else {
				return false;
			}
			return true;
		case T_UINT:
		case T_INT:
		case T_VARINT:
			if (vt == Variant::INT) {
				e.i = int64_t(v);
			} else if (vt == Variant::FLOAT) {
				e.i = to_int(double(v));
			} else if (vt == Variant::BOOL) {
				e.i = bool(v) ? 1 : 0;
			} else {
				return false;
			}
			return true;
		case T_FLOAT:
		case T_FLOAT_RANGE:
		case T_ANGLE:
			if (vt == Variant::FLOAT) {
				e.f = double(v);
			} else if (vt == Variant::INT) {
				e.f = double(int64_t(v));
			} else if (vt == Variant::BOOL) {
				e.f = bool(v) ? 1.0 : 0.0;
			} else {
				return false;
			}
			return true;
		case T_VECTOR3_POSITION:
		case T_VECTOR3_VELOCITY:
		case T_VECTOR3_RANGE:
		case T_DIRECTION:
			if (vt != Variant::VECTOR3) {
				return false;
			}
			e.v3 = v;
			return true;
		case T_QUATERNION:
			if (vt != Variant::QUATERNION) {
				return false;
			}
			e.q = v;
			return true;
		case T_STRING: {
			String s = vt == Variant::STRING ? String(v) : v.stringify();
			CharString utf8 = s.utf8();
			const uint8_t *data = reinterpret_cast<const uint8_t *>(utf8.get_data());
			int64_t n = truncated_string_size(data, utf8.length());
			e.kind = E_BYTES;
			e.bytes = std::make_shared<std::vector<uint8_t>>(data, data + n);
			return true;
		}
		case T_BYTES: {
			if (vt != Variant::PACKED_BYTE_ARRAY) {
				return false;
			}
			PackedByteArray b = v;
			e.kind = E_BYTES;
			e.bytes = std::make_shared<std::vector<uint8_t>>(b.ptr(), b.ptr() + b.size());
			return true;
		}
		default:
			return false;
	}
}

void merge(std::vector<Val> &into, uint64_t &has, uint64_t mask, const Reads &reads) {
	for (uint64_t m = mask; m != 0; m &= m - 1) {
		int s = __builtin_ctzll(m);
		into[s] = reads[s];
	}
	has |= mask;
}

void rebuild_believed(View &v) {
	v.believed_has = v.acked_has;
	for (uint64_t m = v.acked_has; m != 0; m &= m - 1) {
		int s = __builtin_ctzll(m);
		v.believed[s] = v.acked[s];
	}
	for (const Entry &e : v.pending) {
		merge(v.believed, v.believed_has, e.mask, *e.reads);
	}
}

// DotNetBehaviour._sync_view.
void sync_view(View &v, int64_t acked_tick) {
	v.last_ack = acked_tick;
	if (v.pending.empty()) {
		return;
	}
	size_t resolved = 0;
	bool dropped = false;
	while (resolved < v.pending.size()) {
		const Entry &e = v.pending[resolved];
		if (e.tick > acked_tick) {
			break;
		}
		resolved++;
		if (e.tick == acked_tick || !v.strict) {
			merge(v.acked, v.acked_has, e.mask, *e.reads);
		} else {
			dropped = true;
			v.relost |= e.mask;
			v.acked_has &= ~e.mask;
		}
	}
	if (resolved == 0) {
		return;
	}
	v.pending.erase(v.pending.begin(), v.pending.begin() + resolved);
	if (dropped) {
		rebuild_believed(v);
	}
}

// DotNetBehaviour._trim_view.
void trim_view(View &v, int64_t oldest) {
	size_t aged = 0;
	while (aged < v.pending.size()) {
		const Entry &e = v.pending[aged];
		if (e.tick >= oldest) {
			break;
		}
		if (!v.strict) {
			merge(v.acked, v.acked_has, e.mask, *e.reads);
		} else {
			v.relost |= e.mask;
			v.acked_has &= ~e.mask;
		}
		aged++;
	}
	v.pending.erase(v.pending.begin(), v.pending.begin() + aged);
	if (v.strict) {
		rebuild_believed(v);
	}
}

void write_gamma(BitWriter &w, int64_t value) {
	int64_t n = value + 1;
	int width = 0;
	while ((n >> (width + 1)) != 0) {
		width++;
	}
	if (width > 0) {
		w.write_bits(0, width);
	}
	for (int bit = width; bit >= 0; bit--) {
		w.write_bits((n >> bit) & 1, 1);
	}
}

int64_t gamma_bits(int64_t value) {
	int64_t n = value + 1;
	int width = 0;
	while ((n >> (width + 1)) != 0) {
		width++;
	}
	return 2 * width + 1;
}

std::vector<int64_t> unchanged_runs(std::vector<int64_t> ids) {
	std::vector<int64_t> out;
	if (ids.empty()) {
		return out;
	}
	std::sort(ids.begin(), ids.end());
	int64_t start = ids[0];
	int64_t length = 1;
	for (size_t i = 1; i < ids.size(); i++) {
		int64_t id = ids[i];
		if (id == start + length) {
			length++;
		} else if (id >= start + length) {
			out.push_back(start);
			out.push_back(length);
			start = id;
			length = 1;
		}
	}
	out.push_back(start);
	out.push_back(length);
	return out;
}

int64_t tail_bits(const std::vector<int64_t> &runs) {
	int64_t bits = 8 + gamma_bits(int64_t(runs.size() >> 1)) + TRAILER_BITS;
	int64_t cursor = 0;
	for (size_t i = 0; i < runs.size(); i += 2) {
		bits += gamma_bits(runs[i] - cursor) + gamma_bits(runs[i + 1] - 1);
		cursor = runs[i] + runs[i + 1];
	}
	return bits;
}

void write_tail(BitWriter &w, const std::vector<int64_t> &runs) {
	w.write_uint(TAIL_MARK, 8);
	write_gamma(w, int64_t(runs.size() >> 1));
	int64_t cursor = 0;
	for (size_t i = 0; i < runs.size(); i += 2) {
		write_gamma(w, runs[i] - cursor);
		write_gamma(w, runs[i + 1] - 1);
		cursor = runs[i] + runs[i + 1];
	}
}

int64_t clamp_lead(int64_t v) {
	const int64_t span = int64_t(1) << (LEAD_FIELD_BITS - 1);
	return v < -span ? -span : (v > span - 1 ? span - 1 : v);
}

} // namespace

DotNetNativeCore::DotNetNativeCore() {}

DotNetNativeCore::~DotNetNativeCore() {
	_set_workers(0);
}

int64_t DotNetNativeCore::abi_version() {
	return 1;
}

void DotNetNativeCore::_set_workers(int workers) {
	if (workers == int(_threads.size())) {
		_workers = workers;
		return;
	}
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_quit = true;
	}
	_work_cv.notify_all();
	for (std::thread &t : _threads) {
		t.join();
	}
	_threads.clear();
	_quit = false;
	_workers = workers;
	for (int i = 0; i < workers; i++) {
		_threads.emplace_back(&DotNetNativeCore::_worker_loop, this);
	}
}

void DotNetNativeCore::_worker_loop() {
	while (true) {
		Job *job = nullptr;
		{
			std::unique_lock<std::mutex> lock(_mutex);
			_work_cv.wait(lock, [this] { return _quit || _next_job < _jobs.size(); });
			if (_quit) {
				return;
			}
			job = _jobs[_next_job++].get();
		}
		_run_job(job);
		{
			std::lock_guard<std::mutex> lock(_mutex);
			_done_jobs++;
		}
		_done_cv.notify_all();
	}
}

bool DotNetNativeCore::_take_and_run() {
	Job *job = nullptr;
	{
		std::lock_guard<std::mutex> lock(_mutex);
		if (_next_job >= _jobs.size()) {
			return false;
		}
		job = _jobs[_next_job++].get();
	}
	_run_job(job);
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_done_jobs++;
	}
	return true;
}

void DotNetNativeCore::_adopt(BehRec *rec, Object *behaviour) {
	Array spec = behaviour->call("_native_spec");
	rec->decls.clear();
	rec->props.clear();
	rec->decl_count = -1;
	if (spec.size() >= 3) {
		Array props = spec[0];
		Array decls = spec[1];
		for (int64_t i = 0; i < props.size(); i++) {
			rec->props.push_back(props[i]);
		}
		for (int64_t i = 0; i < decls.size(); i++) {
			rec->decls.push_back(decl_from(decls[i]));
		}
		rec->decl_count = spec[2];
	}
	rec->reads.reset();
	for (auto &it : _peers) {
		Peer *peer = it.second.get();
		if (rec->index < int(peer->views.size())) {
			peer->views[rec->index].reset();
		}
	}
	behaviour->set("_native_core", this);
}

void DotNetNativeCore::_read(BehRec *rec, Object *behaviour) {
	Array values = behaviour->call("_native_values");
	size_t n = rec->props.size();
	if (values.size() != int64_t(n) + 3 || int64_t(values[n + 2]) != rec->decl_count) {
		_adopt(rec, behaviour);
		values = behaviour->call("_native_values");
		n = rec->props.size();
		if (values.size() != int64_t(n) + 3) {
			values.resize(n + 3);
		}
	}
	auto reads = std::make_shared<Reads>(n);
	for (size_t s = 0; s < n; s++) {
		(*reads)[s] = make_val(values[s]);
	}
	rec->est_owner = values[n];
	rec->est_other = values[n + 1];
	// The same values as last snapshot share its record, which pending entries hold on to.
	if (rec->reads && rec->reads->size() == n) {
		bool same = true;
		for (size_t s = 0; s < n && same; s++) {
			same = val_equal((*rec->reads)[s], (*reads)[s]);
		}
		if (same) {
			reads = rec->reads;
		}
	}
	rec->reads = reads;
	rec->enc.resize(rec->decls.size());
	for (size_t i = 0; i < rec->decls.size(); i++) {
		const Decl &d = rec->decls[i];
		Enc &e = rec->enc[i];
		e.bytes.reset();
		e.pre.reset();
		const Variant &value = values[d.slot];
		if (native_enc(d, value, e)) {
			continue;
		}
		// A custom codec, or a value DotNetVar.write converts in a way only GDScript knows: encoded
		// by GDScript now, at every bit of a byte it could start at when it may align.
		_custom_reads++;
		int pads = may_align(d.type) ? 8 : 1;
		Array out = behaviour->call("_native_encode", int64_t(i), value, pads);
		auto pre = std::make_shared<PreEncoded>();
		pre->pads = pads;
		for (int p = 0; p < pads && 2 * p + 1 < out.size(); p++) {
			PackedByteArray bytes = out[2 * p];
			pre->data[p].assign(bytes.ptr(), bytes.ptr() + bytes.size());
			pre->bits[p] = out[2 * p + 1];
			// write_run reads whole bytes past the end of the bits.
			pre->data[p].resize(pre->data[p].size() + 8, 0);
		}
		e.kind = E_PRE;
		e.pre = pre;
	}
}

BehRec *DotNetNativeCore::_behaviour_for(Object *behaviour, uint64_t id) {
	auto it = _behaviours.find(id);
	BehRec *rec;
	if (it == _behaviours.end()) {
		auto made = std::make_unique<BehRec>();
		rec = made.get();
		rec->object_id = id;
		if (!_free_indices.empty()) {
			rec->index = _free_indices.back();
			_free_indices.pop_back();
			_by_index[rec->index] = rec;
		} else {
			rec->index = int(_by_index.size());
			_by_index.push_back(rec);
		}
		_behaviours[id] = std::move(made);
		_adopt(rec, behaviour);
	} else {
		rec = it->second.get();
	}
	if (rec->seen != _serial) {
		rec->seen = _serial;
		_read(rec, behaviour);
	}
	return rec;
}

IdRec *DotNetNativeCore::_identity_for(const Variant &identity) {
	Object *obj = identity;
	if (obj == nullptr) {
		return nullptr;
	}
	uint64_t id = obj->get_instance_id();
	auto it = _identities.find(id);
	IdRec *rec;
	if (it == _identities.end()) {
		auto made = std::make_unique<IdRec>();
		rec = made.get();
		rec->object_id = id;
		_identities[id] = std::move(made);
	} else {
		rec = it->second.get();
	}
	if (rec->seen == _serial) {
		return rec;
	}
	rec->seen = _serial;
	rec->net_id = obj->get("net_id");
	rec->owner = obj->get("owner_peer_id");
	rec->shared = int64_t(obj->get("authority")) == _authority_shared;
	Array behaviours = obj->get("behaviours");
	rec->behaviours.clear();
	for (int64_t i = 0; i < behaviours.size(); i++) {
		Object *b = behaviours[i];
		if (b == nullptr) {
			continue;
		}
		BehRec *br = _behaviour_for(b, b->get_instance_id());
		br->owner = rec->owner;
		rec->behaviours.push_back(br);
	}
	return rec;
}

IdRec *DotNetNativeCore::_known_identity(const Variant &identity) const {
	Object *obj = identity;
	if (obj == nullptr) {
		return nullptr;
	}
	auto it = _identities.find(obj->get_instance_id());
	if (it == _identities.end() || it->second->seen != _serial) {
		return nullptr;
	}
	return it->second.get();
}

void DotNetNativeCore::_drop_behaviour(BehRec *rec) {
	for (auto &it : _peers) {
		Peer *peer = it.second.get();
		if (rec->index < int(peer->views.size())) {
			peer->views[rec->index].reset();
		}
	}
	_by_index[rec->index] = nullptr;
	_free_indices.push_back(rec->index);
	_behaviours.erase(rec->object_id);
}

void DotNetNativeCore::_sweep() {
	std::vector<BehRec *> dead;
	for (auto &it : _behaviours) {
		if (it.second->seen != _serial && ObjectDB::get_instance(it.first) == nullptr) {
			dead.push_back(it.second.get());
		}
	}
	for (BehRec *rec : dead) {
		_drop_behaviour(rec);
	}
	for (auto it = _identities.begin(); it != _identities.end();) {
		if (it->second->seen != _serial && ObjectDB::get_instance(it->first) == nullptr) {
			it = _identities.erase(it);
		} else {
			++it;
		}
	}
}

void DotNetNativeCore::begin_snapshot(const Array &identities, const PackedInt64Array &params) {
	if (_open) {
		finish_snapshot();
	}
	int64_t started = usec_now();
	_serial++;
	_snapshots++;
	_tick = params.size() > 0 ? params[0] : 0;
	_now_ms = params.size() > 1 ? params[1] : 0;
	_mtu = params.size() > 2 ? params[2] : 1200;
	_oldest_pending = params.size() > 3 ? params[3] : 0;
	int workers = params.size() > 4 ? int(params[4]) : 0;
	_authority_shared = params.size() > 5 ? params[5] : 1;
	for (int64_t i = 0; i < identities.size(); i++) {
		_identity_for(identities[i]);
	}
	_sweep();
	_set_workers(std::max(0, std::min(workers, 64)));
	_jobs.clear();
	_next_job = 0;
	_done_jobs = 0;
	_open = true;
	_last_build_usec = 0;
	_last_read_usec = usec_now() - started;
}

void DotNetNativeCore::submit_peer(const Array &relevant, const PackedInt64Array &info, const Dictionary &accumulators, const Dictionary &starved_ticks) {
	ERR_FAIL_COND_MSG(!_open, "DotNetNativeCore.submit_peer outside begin_snapshot/finish_snapshot.");
	ERR_FAIL_COND(info.size() < 8);
	auto job = std::make_unique<Job>();
	int64_t peer_id = info[0];
	auto it = _peers.find(peer_id);
	if (it == _peers.end()) {
		auto made = std::make_unique<Peer>();
		made->id = peer_id;
		job->peer = made.get();
		_peers[peer_id] = std::move(made);
	} else {
		job->peer = it->second.get();
	}
	job->acked_tick = info[1];
	job->strict = info[2] != 0;
	job->compact = info[3] != 0;
	job->remaining = info[4];
	job->send_lead = info[5] != 0;
	job->lead_x = info[6];
	job->lead_y = info[7];
	job->accumulators = accumulators;
	job->starved_ticks = starved_ticks;
	job->relevant.reserve(relevant.size());
	// Only identities read in begin_snapshot: reading one here would adopt behaviours and reset
	// views while workers build earlier peers.
	for (int64_t i = 0; i < relevant.size(); i++) {
		IdRec *rec = _known_identity(relevant[i]);
		if (rec != nullptr) {
			job->relevant.push_back(rec);
		} else {
			_unknown_relevant++;
		}
	}
	if (_workers == 0) {
		_run_job(job.get());
		std::lock_guard<std::mutex> lock(_mutex);
		_jobs.push_back(std::move(job));
		_next_job = _jobs.size();
		_done_jobs = _jobs.size();
		return;
	}
	{
		std::lock_guard<std::mutex> lock(_mutex);
		_jobs.push_back(std::move(job));
	}
	_work_cv.notify_one();
}

Array DotNetNativeCore::finish_snapshot() {
	Array out;
	if (!_open) {
		return out;
	}
	int64_t started = usec_now();
	while (_take_and_run()) {
	}
	{
		std::unique_lock<std::mutex> lock(_mutex);
		_done_cv.wait(lock, [this] { return _done_jobs >= _jobs.size(); });
	}
	_last_wait_usec = usec_now() - started;
	for (auto &jp : _jobs) {
		Job *job = jp.get();
		_last_build_usec += job->usec;
		Array payloads;
		for (const std::vector<uint8_t> &p : job->payloads) {
			PackedByteArray bytes;
			bytes.resize(int64_t(p.size()));
			if (!p.empty()) {
				memcpy(bytes.ptrw(), p.data(), p.size());
			}
			payloads.push_back(bytes);
		}
		PackedInt32Array counts;
		for (int32_t c : job->counts) {
			counts.push_back(c);
		}
		Array r;
		r.push_back(job->peer->id);
		r.push_back(payloads);
		r.push_back(counts);
		r.push_back(job->starved);
		r.push_back(job->spent);
		r.push_back(job->split);
		r.push_back(job->unchanged_listed);
		r.push_back(job->unchanged_saved);
		r.push_back(job->leads_sent);
		r.push_back(job->oversize_id);
		r.push_back(job->oversize_bytes);
		out.push_back(r);
	}
	_jobs.clear();
	_next_job = 0;
	_done_jobs = 0;
	_open = false;
	return out;
}

// DotNetBehaviour._collect_dirty, the per-peer rule: what the shared-set shortcut there gives too.
uint64_t DotNetNativeCore::_collect(View &view, const BehRec &rec, int64_t peer_id, bool until_acked) const {
	uint64_t out = 0;
	const Reads &reads = *rec.reads;
	const int64_t owner = rec.owner;
	for (size_t i = 0; i < rec.decls.size(); i++) {
		const Decl &d = rec.decls[i];
		if (d.audience == AUD_OWNER) {
			if (peer_id != owner) {
				continue;
			}
		} else if (d.audience == AUD_OBSERVERS) {
			if (peer_id == owner) {
				continue;
			}
		}
		const int s = d.slot;
		const uint64_t bit = uint64_t(1) << s;
		if (d.max_rate > 0.0) {
			double interval = 1000.0 / d.max_rate;
			double last = (view.sent_has & bit) ? double(view.last_sent[s]) : -100000.0;
			if (double(_now_ms) - last < interval) {
				continue;
			}
		}
		const Val &current = reads[s];
		bool dirty;
		if (!(view.believed_has & bit)) {
			dirty = true;
		} else if (d.epsilon <= 0.0) {
			dirty = !val_equal(view.believed[s], current);
		} else {
			dirty = differs(d, view.believed[s], current);
		}
		if (d.on_spawn_only && !dirty) {
			continue;
		}
		bool owed = until_acked;
		bool unconfirmed_known = false;
		bool unconfirmed = false;
		if (!owed && (view.relost & bit)) {
			unconfirmed = !(view.acked_has & bit) || differs(d, view.acked[s], current);
			unconfirmed_known = true;
			if (unconfirmed) {
				owed = true;
			} else {
				view.relost &= ~bit;
			}
		}
		if (!dirty) {
			if (!owed) {
				continue;
			}
			if (!unconfirmed_known) {
				unconfirmed = !(view.acked_has & bit) || differs(d, view.acked[s], current);
			}
			if (!unconfirmed) {
				continue;
			}
		}
		out |= uint64_t(1) << i;
	}
	return out;
}

void DotNetNativeCore::_write_value(BitWriter &w, const Decl &d, const Enc &e) const {
	if (e.kind == E_PRE) {
		const PreEncoded &pre = *e.pre;
		int p = pre.pads == 8 ? int(w.bit_pos & 7) : 0;
		w.write_run(pre.data[p].data(), p, pre.bits[p]);
		return;
	}
	if (e.kind == E_BYTES) {
		w.write_bytes(e.bytes->data(), int64_t(e.bytes->size()));
		return;
	}
	switch (d.type) {
		case T_BOOL:
			w.write_bool(e.i != 0);
			break;
		case T_UINT:
			w.write_uint(e.i, d.bit_width);
			break;
		case T_INT:
			w.write_int(e.i, d.bit_width);
			break;
		case T_VARINT:
			w.write_svarint(e.i);
			break;
		case T_FLOAT:
			w.write_float32(e.f);
			break;
		case T_FLOAT_RANGE:
			w.write_float_range(e.f, d.min_value, d.max_value, d.bit_width);
			break;
		case T_VECTOR3_POSITION:
			w.write_vector3_range(e.v3, -d.extent, d.extent, d.position_bits);
			break;
		case T_VECTOR3_VELOCITY:
			w.write_vector3_range(e.v3, -d.max_speed, d.max_speed, d.velocity_bits);
			break;
		case T_VECTOR3_RANGE:
			w.write_vector3_range(e.v3, d.min_value, d.max_value, d.bit_width);
			break;
		case T_DIRECTION:
			w.write_direction(e.v3, d.bit_width);
			break;
		case T_QUATERNION:
			w.write_quaternion(e.q, d.rotation_bits);
			break;
		case T_ANGLE:
			w.write_angle(e.f, d.bit_width);
			break;
		default:
			break;
	}
}

// DotNetBehaviour.write_state: the set, then the record of it.
void DotNetNativeCore::_write_state(BitWriter &w, View &view, const BehRec &rec, uint64_t mask) const {
	w.write_uint(__builtin_popcountll(mask), 6);
	uint64_t slots = 0;
	uint64_t rated = 0;
	for (uint64_t m = mask; m != 0; m &= m - 1) {
		int i = __builtin_ctzll(m);
		const Decl &d = rec.decls[i];
		w.write_uint(i, 6);
		_write_value(w, d, rec.enc[i]);
		slots |= uint64_t(1) << d.slot;
		if (d.max_rate > 0.0) {
			rated |= uint64_t(1) << d.slot;
		}
	}
	if (slots == 0) {
		return;
	}
	merge(view.believed, view.believed_has, slots, *rec.reads);
	for (uint64_t m = rated; m != 0; m &= m - 1) {
		view.last_sent[__builtin_ctzll(m)] = _now_ms;
	}
	view.sent_has |= rated;
	if (_tick <= 0) {
		merge(view.acked, view.acked_has, slots, *rec.reads);
		return;
	}
	view.pending.push_back(Entry{ _tick, slots, rec.reads });
}

int64_t DotNetNativeCore::_state_bits(const BehRec &rec, uint64_t mask, int64_t at) const {
	BitWriter w;
	int pad = int(at & 7);
	if (pad > 0) {
		w.write_bits(0, pad);
	}
	w.write_uint(__builtin_popcountll(mask), 6);
	for (uint64_t m = mask; m != 0; m &= m - 1) {
		int i = __builtin_ctzll(m);
		w.write_uint(i, 6);
		_write_value(w, rec.decls[i], rec.enc[i]);
	}
	return w.bit_length() - pad;
}

void DotNetNativeCore::_begin_part(BitWriter &w) const {
	w.reset();
	w.bytes.reserve(size_t(_mtu) + 16);
	w.write_uint(_tick, 32);
	w.write_uint(0, 12);
}

// DotNetManager._build_peer, which is _send_to_peer on a worker.
void DotNetNativeCore::_run_job(Job *job) {
	int64_t started = usec_now();
	const int64_t peer_id = job->peer->id;
	int64_t limit_bits = _mtu * 8 - TRAILER_BITS;
	if (job->send_lead) {
		limit_bits -= tail_bits({}) + LEAD_BITS;
	}
	std::vector<BitWriter> parts(1);
	std::vector<int32_t> counts(1, 0);
	_begin_part(parts[0]);
	int64_t written = 0;
	int64_t remaining = job->remaining;
	std::vector<int64_t> unchanged;
	int64_t unchanged_header_bits = 0;
	std::vector<uint64_t> masks;
	std::vector<View *> views;
	const Variant zero_f = 0.0;
	const Variant zero_i = int64_t(0);

	for (IdRec *identity : job->relevant) {
		const bool predicted = identity->owner == peer_id && identity->shared;
		masks.clear();
		views.clear();
		bool anything = false;
		for (BehRec *b : identity->behaviours) {
			View *v = job->peer->view(b->index);
			v->ensure(b->props.size());
			if (job->strict) {
				v->strict = true;
			}
			if (job->acked_tick > v->last_ack) {
				sync_view(*v, job->acked_tick);
			}
			if (!v->pending.empty() && v->pending.front().tick < _oldest_pending) {
				trim_view(*v, _oldest_pending);
			}
			uint64_t m = b->reads ? _collect(*v, *b, peer_id, predicted) : 0;
			masks.push_back(m);
			views.push_back(v);
			anything = anything || m != 0;
		}
		const Variant key = identity->net_id;
		if (job->compact && !anything) {
			unchanged.push_back(identity->net_id);
			unchanged_header_bits += ID_BITS + 6 + 6 * int64_t(identity->behaviours.size());
			job->accumulators[key] = zero_f;
			job->starved_ticks[key] = zero_i;
			continue;
		}
		int64_t estimated = 0;
		for (BehRec *b : identity->behaviours) {
			estimated += peer_id == b->owner ? b->est_owner : b->est_other;
		}
		estimated = (estimated + 7) >> 3;
		if (written > 0 && estimated > remaining) {
			job->starved++;
			continue;
		}
		BitWriter *w = &parts.back();
		if (counts.back() > 0 && w->bit_length() + estimated * 16 + 256 > limit_bits) {
			int64_t at = w->bit_length() + ID_BITS + 6;
			for (size_t b = 0; b < identity->behaviours.size(); b++) {
				at += _state_bits(*identity->behaviours[b], masks[b], at);
			}
			if (at > limit_bits) {
				if (parts.size() >= MAX_PARTS) {
					job->starved++;
					continue;
				}
				parts.emplace_back();
				_begin_part(parts.back());
				counts.push_back(0);
				w = &parts.back();
			}
		}
		const int64_t before = w->byte_length();
		w->write_bits((identity->net_id & ((int64_t(1) << ID_BITS) - 1)) | ((int64_t(identity->behaviours.size()) & 0x3F) << ID_BITS), ID_BITS + 6);
		for (size_t b = 0; b < identity->behaviours.size(); b++) {
			_write_state(*w, *views[b], *identity->behaviours[b], masks[b]);
		}
		if (w->bit_length() > limit_bits && job->oversize_id < 0) {
			job->oversize_id = identity->net_id;
			job->oversize_bytes = (w->bit_length() + 7) >> 3;
		}
		const int64_t spent = w->byte_length() - before;
		remaining -= spent;
		job->spent += spent;
		job->accumulators[key] = zero_f;
		job->starved_ticks[key] = zero_i;
		counts.back()++;
		written++;
	}

	if (parts.size() > 1 && counts.back() == 0) {
		parts.pop_back();
		counts.pop_back();
	}

	int tail_part = -1;
	std::vector<int64_t> runs = unchanged_runs(unchanged);
	if (!runs.empty()) {
		int64_t bits = tail_bits(runs);
		if (parts.back().bit_length() + bits <= limit_bits + TRAILER_BITS) {
			tail_part = int(parts.size()) - 1;
		} else if (parts.size() < MAX_PARTS) {
			parts.emplace_back();
			_begin_part(parts.back());
			counts.push_back(0);
			tail_part = int(parts.size()) - 1;
		} else {
			job->starved++;
		}
		if (tail_part >= 0) {
			job->unchanged_listed += int64_t(unchanged.size());
			job->unchanged_saved += std::max<int64_t>(0, (unchanged_header_bits - bits) >> 3);
		}
	}

	const int total = int(parts.size());
	job->split = total > 1;
	for (int index = 0; index < total; index++) {
		BitWriter &part = parts[index];
		if (index == tail_part) {
			write_tail(part, runs);
			part.write_uint(index, 4);
			part.write_uint(total - 1, 4);
		} else if (job->send_lead) {
			write_tail(part, {});
			part.write_uint(index, 4);
			part.write_uint(total - 1, 4);
		} else if (total > 1) {
			part.write_uint(index, 4);
			part.write_uint(total - 1, 4);
		}
		if (job->send_lead) {
			part.write_int(clamp_lead(job->lead_x), LEAD_FIELD_BITS);
			part.write_int(clamp_lead(job->lead_y - _tick), LEAD_FIELD_BITS);
			job->leads_sent++;
		}
		std::vector<uint8_t> payload = std::move(part.bytes);
		const int32_t count = counts[index];
		if (COUNT_BYTE + 1 < int(payload.size())) {
			payload[COUNT_BYTE] = uint8_t(count & 0xFF);
			payload[COUNT_BYTE + 1] = uint8_t((payload[COUNT_BYTE + 1] & 0xF0) | ((count >> 8) & 0x0F));
		}
		job->payloads.push_back(std::move(payload));
		job->counts.push_back(count + (index == tail_part ? int32_t(unchanged.size()) : 0));
	}
	job->usec = usec_now() - started;
}

void DotNetNativeCore::forget_peer(int64_t peer_id) {
	ERR_FAIL_COND_MSG(_open, "DotNetNativeCore.forget_peer inside a snapshot.");
	_peers.erase(peer_id);
}

void DotNetNativeCore::forget_view(Object *behaviour, int64_t peer_id) {
	ERR_FAIL_COND_MSG(_open, "DotNetNativeCore.forget_view inside a snapshot.");
	if (behaviour == nullptr) {
		return;
	}
	auto it = _behaviours.find(behaviour->get_instance_id());
	if (it == _behaviours.end()) {
		return;
	}
	const int index = it->second->index;
	for (auto &p : _peers) {
		if (peer_id >= 0 && p.first != peer_id) {
			continue;
		}
		if (index < int(p.second->views.size())) {
			p.second->views[index].reset();
		}
	}
}

Dictionary DotNetNativeCore::_view_dict(const View &view, const BehRec &rec) const {
	auto values = [&rec](const std::vector<Val> &vals, uint64_t has) {
		Dictionary d;
		for (uint64_t m = has; m != 0; m &= m - 1) {
			int s = __builtin_ctzll(m);
			d[rec.props[s]] = to_variant(vals[s]);
		}
		return d;
	};
	Dictionary out;
	out["acked"] = values(view.acked, view.acked_has);
	out["believed"] = values(view.believed, view.believed_has);
	Array entries;
	for (const Entry &e : view.pending) {
		Array entry;
		entry.push_back(e.tick);
		entry.push_back(values(*e.reads, e.mask));
		entries.push_back(entry);
	}
	out["pending"] = entries;
	Dictionary sent;
	for (uint64_t m = view.sent_has; m != 0; m &= m - 1) {
		int s = __builtin_ctzll(m);
		sent[rec.props[s]] = view.last_sent[s];
	}
	out["last_sent_ms"] = sent;
	out["last_ack"] = view.last_ack;
	Dictionary relost;
	for (uint64_t m = view.relost; m != 0; m &= m - 1) {
		relost[rec.props[__builtin_ctzll(m)]] = true;
	}
	out["relost"] = relost;
	out["strict"] = view.strict;
	return out;
}

Dictionary DotNetNativeCore::view_snapshot(Object *behaviour, int64_t peer_id) {
	if (behaviour == nullptr) {
		return Dictionary();
	}
	auto it = _behaviours.find(behaviour->get_instance_id());
	auto peer = _peers.find(peer_id);
	if (it == _behaviours.end() || peer == _peers.end()) {
		return Dictionary();
	}
	const int index = it->second->index;
	if (index >= int(peer->second->views.size()) || !peer->second->views[index] || peer->second->views[index]->is_fresh()) {
		return Dictionary();
	}
	return _view_dict(*peer->second->views[index], *it->second);
}

Dictionary DotNetNativeCore::view_state(Object *behaviour, int64_t peer_id) {
	if (behaviour == nullptr) {
		return Dictionary();
	}
	auto it = _behaviours.find(behaviour->get_instance_id());
	auto peer = _peers.find(peer_id);
	if (it == _behaviours.end() || peer == _peers.end()) {
		return Dictionary();
	}
	const int index = it->second->index;
	if (index >= int(peer->second->views.size()) || !peer->second->views[index]) {
		return Dictionary();
	}
	const View &v = *peer->second->views[index];
	Dictionary out;
	out["acked"] = __builtin_popcountll(v.acked_has);
	out["believed"] = __builtin_popcountll(v.believed_has);
	out["pending"] = int64_t(v.pending.size());
	out["last_ack"] = v.last_ack;
	out["strict"] = v.strict;
	return out;
}

Array DotNetNativeCore::encode_value(const PackedFloat64Array &spec, const Variant &value, int64_t pad) {
	Array out;
	Decl d = decl_from(spec);
	Enc e;
	if (!native_enc(d, value, e)) {
		return out;
	}
	BitWriter w;
	int p = int(pad & 7);
	if (p > 0) {
		w.write_bits(0, p);
	}
	_write_value(w, d, e);
	PackedByteArray bytes;
	bytes.resize(int64_t(w.bytes.size()));
	if (!w.bytes.empty()) {
		memcpy(bytes.ptrw(), w.bytes.data(), w.bytes.size());
	}
	out.push_back(bytes);
	out.push_back(w.bit_length() - p);
	return out;
}

Dictionary DotNetNativeCore::describe() {
	Dictionary out;
	int64_t views = 0;
	for (auto &p : _peers) {
		for (auto &v : p.second->views) {
			views += v ? 1 : 0;
		}
	}
	out["abi"] = abi_version();
	out["behaviours"] = int64_t(_behaviours.size());
	out["identities"] = int64_t(_identities.size());
	out["peers"] = int64_t(_peers.size());
	out["views"] = views;
	out["workers"] = _workers;
	out["snapshots"] = _snapshots;
	out["read_usec"] = _last_read_usec;
	out["build_usec"] = _last_build_usec;
	out["wait_usec"] = _last_wait_usec;
	out["gdscript_encodes"] = _custom_reads;
	out["unknown_relevant"] = _unknown_relevant;
	return out;
}

void DotNetNativeCore::_bind_methods() {
	ClassDB::bind_static_method("DotNetNativeCore", D_METHOD("abi_version"), &DotNetNativeCore::abi_version);
	ClassDB::bind_method(D_METHOD("begin_snapshot", "identities", "params"), &DotNetNativeCore::begin_snapshot);
	ClassDB::bind_method(D_METHOD("submit_peer", "relevant", "info", "accumulators", "starved_ticks"), &DotNetNativeCore::submit_peer);
	ClassDB::bind_method(D_METHOD("finish_snapshot"), &DotNetNativeCore::finish_snapshot);
	ClassDB::bind_method(D_METHOD("forget_peer", "peer_id"), &DotNetNativeCore::forget_peer);
	ClassDB::bind_method(D_METHOD("forget_view", "behaviour", "peer_id"), &DotNetNativeCore::forget_view);
	ClassDB::bind_method(D_METHOD("view_snapshot", "behaviour", "peer_id"), &DotNetNativeCore::view_snapshot);
	ClassDB::bind_method(D_METHOD("view_state", "behaviour", "peer_id"), &DotNetNativeCore::view_state);
	ClassDB::bind_method(D_METHOD("encode_value", "spec", "value", "pad"), &DotNetNativeCore::encode_value);
	ClassDB::bind_method(D_METHOD("describe"), &DotNetNativeCore::describe);
}
