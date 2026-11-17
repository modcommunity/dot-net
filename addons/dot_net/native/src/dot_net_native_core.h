#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/vector3i.hpp>

#include <cmath>
#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include "net_writer.h"

namespace dotnet {

// One replicated value as read for a snapshot. The common types are held natively so that
// comparing two is a few instructions on any thread; anything else is a shared Variant.
struct Val {
	uint8_t vt = 0;
	union {
		bool b;
		int64_t i;
		double f;
		float v[4];
	} u = {};
	std::shared_ptr<const godot::Variant> ext;
};

// One DotNetVar, as DotNetBehaviour._native_spec describes it.
struct Decl {
	int type = 0;
	int audience = 0;
	double max_rate = 0.0;
	double epsilon = 0.0;
	bool on_spawn_only = false;
	int bit_width = 32;
	double min_value = -1.0;
	double max_value = 1.0;
	double extent = 2048.0;
	int position_bits = 19;
	double max_speed = 100.0;
	int velocity_bits = 12;
	int rotation_bits = 9;
	int slot = 0;
};

// What one declaration encodes this snapshot, converted on the main thread.
struct PreEncoded {
	int pads = 1;
	std::vector<uint8_t> data[8];
	int64_t bits[8] = {};
};

struct Enc {
	uint8_t kind = 0;
	int64_t i = 0;
	double f = 0.0;
	godot::Vector3 v3;
	godot::Quaternion q;
	std::shared_ptr<std::vector<uint8_t>> bytes;
	std::shared_ptr<PreEncoded> pre;
};

using Reads = std::vector<Val>;

struct BehRec {
	uint64_t object_id = 0;
	int index = -1;
	std::vector<Decl> decls;
	std::vector<godot::StringName> props;
	int64_t decl_count = -1;
	uint64_t seen = 0;
	// This snapshot's.
	std::shared_ptr<Reads> reads;
	std::vector<Enc> enc;
	int64_t est_owner = 0;
	int64_t est_other = 0;
	int64_t owner = 0;
	// Direct reads: the decl count and owner est_owner/est_other were asked for (-2: never).
	int64_t est_count = -2;
	int64_t est_for_owner = 0;
	// _native_spec's fourth entry: no script overrides a read hook, so the core reads the values itself.
	bool direct = false;
};

struct IdRec {
	uint64_t object_id = 0;
	int64_t net_id = 0;
	int64_t owner = 0;
	bool shared = false;
	uint64_t seen = 0;
	std::vector<BehRec *> behaviours;
	// Read only when native interest is on (DotNetNativeCore::set_interest).
	double priority = 1.0;
	bool always = false;
	double linger_sec = 2.0;
	godot::Vector3 pos;
	// Its visibility cluster this snapshot, when the interest has a vis tree.
	int32_t cluster = -1;
	double radius = 0.0;
	double score_limit = 1.0;
	double far_dist = 0.0;
};

// DotNetInterest's per-peer cache and lingering set, in the order the GDScript dictionaries keep them.
struct PeerInterest {
	bool has = false;
	int64_t at_ms = 0;
	std::vector<int64_t> order;
	std::unordered_set<int64_t> ids;
	std::vector<std::pair<int64_t, int64_t>> linger;
};

// DotNetVisibility, copied when its serial changes: the map's BSP tree (planes, nodes, leaf clusters) and a
// decoded PVS bit row per cluster. cluster_of and sees are DotNetVisibility.cluster_of and cluster_sees.
struct VisTree {
	int64_t serial = 0;
	std::vector<float> planes;
	std::vector<int32_t> nodes;
	std::vector<int32_t> leaf_cluster;
	int32_t head = 0;
	int64_t row_bytes = 0;
	int64_t clusters = 0;
	bool bounded = false;
	godot::Vector3 lo, hi;
	std::vector<uint8_t> rows;

	// The walk in doubles, term by term as GDScript evaluates it, so both pick the same side of a plane.
	int32_t cluster_of(const godot::Vector3 &p) const {
		if (bounded && (p.x < lo.x || p.y < lo.y || p.z < lo.z || p.x > hi.x || p.y > hi.y || p.z > hi.z)) {
			return -1;
		}
		int32_t node = head;
		size_t guard = nodes.size() / 3 + 1;
		while (node >= 0 && guard > 0) {
			guard--;
			const int32_t *n = nodes.data() + size_t(node) * 3;
			const float *pl = planes.data() + size_t(n[0]) * 4;
			double d = double(pl[0]) * double(p.x) + double(pl[1]) * double(p.y) + double(pl[2]) * double(p.z) - double(pl[3]);
			node = d >= 0.0 ? n[1] : n[2];
		}
		if (node >= 0) {
			return -1;
		}
		size_t leaf = size_t(-1 - int64_t(node));
		return leaf < leaf_cluster.size() ? leaf_cluster[leaf] : -1;
	}
	bool sees(int32_t from, int32_t to) const {
		if (from < 0 || to < 0 || from >= clusters || to >= clusters) {
			return true;
		}
		return (rows[size_t(from) * size_t(row_bytes) + size_t(to >> 3)] & (1u << (to & 7))) != 0;
	}
};

struct InterestCfg {
	bool on = false;
	double radius = 200.0;
	std::vector<std::pair<godot::String, double>> radius_by_tag;
	double interval_sec = 0.25;
	int64_t far_every = 1;
	double far_distance = 0.0;
	std::vector<std::pair<godot::String, double>> far_by_tag;
	bool far_coherent = false;
	int64_t far_tiers = 1;
	// cos of DotNetInterest.aim_cone_deg; 1 is off.
	double aim_cos = 1.0;
	int64_t ticks_per_snapshot = 1;
	int64_t cap = 0;
	int64_t send_budget = 0;
	int64_t starvation_ticks = 10;
	double starvation_weight = 1.0;
	int64_t invalidation = 0;
	std::shared_ptr<const VisTree> vis;
	double vis_audible = 0.0;
	bool thins() const { return far_every > 1 && (far_distance > 0.0 || !far_by_tag.empty()); }
};

struct Entry {
	int64_t tick = 0;
	uint64_t mask = 0;
	std::shared_ptr<Reads> reads;
};

// DotNetBehaviour.PeerView, with properties as slots and dictionaries as bitmasks.
struct View {
	uint64_t acked_has = 0;
	uint64_t believed_has = 0;
	uint64_t relost = 0;
	uint64_t sent_has = 0;
	std::vector<Val> acked;
	std::vector<Val> believed;
	std::vector<int64_t> last_sent;
	std::deque<Entry> pending;
	int64_t last_ack = 0;
	bool strict = false;

	void ensure(size_t n) {
		if (acked.size() < n) {
			acked.resize(n);
			believed.resize(n);
			last_sent.resize(n);
		}
	}
	bool is_fresh() const {
		return pending.empty() && believed_has == 0 && acked_has == 0 && sent_has == 0 && relost == 0 && last_ack == 0 && !strict;
	}
};

// A peer's DotNetBudget.PeerBudget accumulators and starved_ticks, held here between snapshots of the
// native-interest path so the build threads read and write plain numbers instead of Godot Dictionaries.
// Each key keeps its first insertion's place, as a Dictionary does, so export() rebuilds the same
// dictionaries the GDScript path would hold. A key read but never set is not exported (Dictionary.get).
struct BudgetStore {
	enum : uint8_t { HAS_ACC = 1, HAS_STARVED = 2 };
	std::unordered_map<int64_t, size_t> slots;
	std::vector<int64_t> ids;
	std::vector<double> acc;
	std::vector<int64_t> starved;
	std::vector<uint8_t> has;
	std::vector<size_t> acc_order;
	std::vector<size_t> starved_order;
	// Whether the GDScript side handed this store its dictionaries (submit's load flag) since it was made.
	bool loaded = false;

	void clear() {
		slots.clear();
		ids.clear();
		acc.clear();
		starved.clear();
		has.clear();
		acc_order.clear();
		starved_order.clear();
	}
	size_t slot(int64_t id) {
		auto [it, inserted] = slots.try_emplace(id, ids.size());
		if (inserted) {
			ids.push_back(id);
			acc.push_back(0.0);
			starved.push_back(0);
			has.push_back(0);
		}
		return it->second;
	}
	double get_acc(size_t s) const { return (has[s] & HAS_ACC) ? acc[s] : 0.0; }
	int64_t get_starved(size_t s) const { return (has[s] & HAS_STARVED) ? starved[s] : 0; }
	void set_acc(size_t s, double v) {
		if (!(has[s] & HAS_ACC)) {
			has[s] |= HAS_ACC;
			acc_order.push_back(s);
		}
		acc[s] = v;
	}
	void set_starved(size_t s, int64_t v) {
		if (!(has[s] & HAS_STARVED)) {
			has[s] |= HAS_STARVED;
			starved_order.push_back(s);
		}
		starved[s] = v;
	}
};

struct Peer {
	int64_t id = 0;
	PeerInterest interest;
	BudgetStore budget;
	std::vector<std::unique_ptr<View>> views;
	View *view(int index) {
		if (index >= int(views.size())) {
			views.resize(index + 1);
		}
		if (!views[index]) {
			views[index] = std::make_unique<View>();
		}
		return views[index].get();
	}
};

struct Job {
	Peer *peer = nullptr;
	std::vector<IdRec *> relevant;
	int64_t acked_tick = 0;
	// DotNetManager.acked_ring: tick t acked when acked_ring[t % size] == t; empty = none.
	std::vector<int64_t> acked_ring;
	bool strict = false;
	bool compact = false;
	bool send_lead = false;
	int64_t remaining = 0;
	int64_t lead_x = 0;
	int64_t lead_y = 0;
	godot::Dictionary accumulators;
	godot::Dictionary starved_ticks;
	// The peer's BudgetStore, which replaces the two dictionaries (native interest only), or null.
	BudgetStore *store = nullptr;
	// Native interest: the build ranks its own candidates (see DotNetNativeCore::_interest_job).
	bool interest = false;
	bool has_observer = false;
	godot::Vector3 obs_pos;
	int64_t obs_owner = -1;
	// The observer's DotNetIdentity.interest_aim (unit, or zero for none).
	godot::Vector3 obs_aim;
	int64_t cap_count = 0;
	// Out.
	std::vector<std::vector<uint8_t>> payloads;
	std::vector<int32_t> counts;
	int64_t starved = 0;
	int64_t spent = 0;
	bool split = false;
	int64_t unchanged_listed = 0;
	int64_t unchanged_saved = 0;
	int64_t leads_sent = 0;
	int64_t oversize_id = -1;
	int64_t oversize_bytes = 0;
	int64_t usec = 0;
	// Built: set under DotNetNativeCore::_mutex once the payloads above are final.
	bool done = false;
};

} // namespace dotnet

namespace godot {

/// The per-peer half of DotNetManager's snapshot send, in C++: what each peer is believed to hold,
/// what is dirty for it, and its snapshot parts, bit for bit what the GDScript path builds.
/// One per manager; it keeps no global state. Server side only: DotNetNative loads it.
class DotNetNativeCore : public RefCounted {
	GDCLASS(DotNetNativeCore, RefCounted)

	std::unordered_map<uint64_t, std::unique_ptr<dotnet::BehRec>> _behaviours;
	std::vector<dotnet::BehRec *> _by_index;
	std::vector<int> _free_indices;
	std::unordered_map<uint64_t, std::unique_ptr<dotnet::IdRec>> _identities;
	std::unordered_map<int64_t, std::unique_ptr<dotnet::Peer>> _peers;

	uint64_t _serial = 0;
	int64_t _tick = 0;
	int64_t _now_ms = 0;
	int64_t _mtu = 1200;
	int64_t _oldest_pending = 0;
	int64_t _authority_shared = 0;
	bool _open = false;

	// Jobs of the open snapshot, in submission order, and the threads that build them.
	std::vector<std::unique_ptr<dotnet::Job>> _jobs;
	size_t _next_job = 0;
	size_t _done_jobs = 0;
	// Jobs already handed back by take_ready, a prefix of _jobs.
	size_t _taken = 0;
	std::mutex _mutex;
	std::condition_variable _work_cv;
	std::condition_variable _done_cv;
	std::vector<std::thread> _threads;
	bool _quit = false;
	int _workers = 0;

	dotnet::InterestCfg _icfg;
	std::vector<dotnet::IdRec *> _all;
	std::unordered_map<int64_t, dotnet::IdRec *> _by_net;
	int64_t _interest_usec = 0;

	int64_t _last_build_usec = 0;
	int64_t _last_wait_usec = 0;
	int64_t _last_read_usec = 0;
	int64_t _snapshots = 0;
	int64_t _custom_reads = 0;
	int64_t _unknown_relevant = 0;
	// How a behaviour's values are read (begin_snapshot params[6], DotNetConfig.native_reads):
	// 0 calls GDScript's _native_values per behaviour, 1 reads the properties directly, 2 does both and
	// compares (a mismatch counts, logs once and sends GDScript's values).
	int _read_mode = 1;
	int64_t _read_mismatches = 0;
	bool _mismatch_logged = false;

	dotnet::BehRec *_behaviour_for(Object *behaviour, uint64_t id, int64_t owner);
	dotnet::IdRec *_identity_for(const Variant &identity);
	dotnet::IdRec *_known_identity(const Variant &identity) const;
	void _adopt(dotnet::BehRec *rec, Object *behaviour);
	void _read(dotnet::BehRec *rec, Object *behaviour, int64_t owner);
	Array _direct_values(dotnet::BehRec *rec, Object *behaviour, int64_t owner);
	Array _values(dotnet::BehRec *rec, Object *behaviour, int64_t owner);
	godot::Vector3 _position_of(Object *identity);
	void _mismatch(const char *what, Object *obj);
	void _drop_behaviour(dotnet::BehRec *rec);
	void _sweep();
	void _set_workers(int workers);
	void _worker_loop();
	void _run_job(dotnet::Job *job);
	void _interest_job(dotnet::Job *job);
	static std::shared_ptr<const dotnet::VisTree> _vis_tree(const Dictionary &d, const std::shared_ptr<const dotnet::VisTree> &kept);
	dotnet::Peer *_peer_for(int64_t peer_id);
	static bool _load_budget(dotnet::BudgetStore &store, const Dictionary &accumulators, const Dictionary &starved_ticks);
	void _queue(std::unique_ptr<dotnet::Job> job);
	bool _take_and_run();
	void _mark_done(dotnet::Job *job);
	Array _result(dotnet::Job *job);

	uint64_t _collect(dotnet::View &view, const dotnet::BehRec &rec, int64_t peer_id, bool until_acked) const;
	void _write_state(dotnet::BitWriter &w, dotnet::View &view, const dotnet::BehRec &rec, uint64_t mask) const;
	int64_t _state_bits(const dotnet::BehRec &rec, uint64_t mask, int64_t at) const;
	void _write_value(dotnet::BitWriter &w, const dotnet::Decl &d, const dotnet::Enc &e) const;
	void _begin_part(dotnet::BitWriter &w) const;
	Dictionary _view_dict(const dotnet::View &view, const dotnet::BehRec &rec) const;

protected:
	static void _bind_methods();

public:
	DotNetNativeCore();
	~DotNetNativeCore();

	/// Bumped whenever the GDScript side must change with the library.
	static int64_t abi_version();

	/// Opens a snapshot: reads every identity's behaviours once, on this thread.
	/// [param params]: tick, now_ms, mtu, oldest pending tick, workers, Authority.SHARED's value.
	void begin_snapshot(const Array &identities, const PackedInt64Array &params);
	/// Queues one peer's build. [param info]: peer_id, acked_tick, strict, compact, remaining bytes,
	/// send_lead, lead.x, lead.y, then the acked ring (ABI 4): its size n and n ticks
	/// (DotNetManager.acked_ring). The budget dictionaries are the peer's own and are written by the build.
	void submit_peer(const Array &relevant, const PackedInt64Array &info, const Dictionary &accumulators, const Dictionary &starved_ticks);
	/// Native interest (off unless [param cfg] has on = true): DotNetInterestDistance's relevance, thinning,
	/// scores, entity cap and the budget's accumulator order, run by the build itself. Call before begin_snapshot.
	void set_interest(const Dictionary &cfg);
	/// Whether set_interest reads a "vis" tree (DotNetVisibility.native_dict). Its presence is the check.
	static bool visibility_supported();
	/// Marks every peer's cached relevance as old (what a test does to DotNetInterest._cache's at_ms).
	void expire_interest();
	/// submit_peer for a peer whose candidates the library works out: [param observer] is its entity or null,
	/// [param info] as submit_peer's with a load flag
	/// at index 8 and the acked ring after it. The budget lives in the library between snapshots:
	/// with load = 1 it is read from the two dictionaries first; with 0 the library's copy is newer than them
	/// and they are not touched (export_budget writes them back).
	void submit_peer_interest(const Variant &observer, const PackedInt64Array &info, const Dictionary &accumulators, const Dictionary &starved_ticks);
	/// Rewrites [param accumulators] and [param starved_ticks] with the library's budget of [param peer_id],
	/// keys in the order the dictionaries would have them. Outside a snapshot only.
	void export_budget(int64_t peer_id, Dictionary accumulators, Dictionary starved_ticks);
	/// Waits for every queued build and returns one result per peer, in submission order:
	/// [peer_id, payloads, entity counts, starved, spent, split, unchanged_listed, unchanged_saved,
	/// leads_sent, oversize net id or -1, oversize bytes, entities relevant before the cap].
	Array finish_snapshot();
	/// The results of the next built peers in submission order, as finish_snapshot gives them: waits
	/// (building one itself meanwhile) until the first peer not yet taken is built, then returns it and
	/// every peer after it that is built too. Empty once every peer is taken. Lets the caller send
	/// earlier peers while the workers build later ones; finish_snapshot still closes the snapshot and
	/// returns whatever is left.
	Array take_ready();

	void forget_peer(int64_t peer_id);
	/// Forgets one behaviour's record of one peer (-1: every peer).
	void forget_view(Object *behaviour, int64_t peer_id);
	/// DotNetBehaviour.PeerView.snapshot()'s fields for the native record, or {} when there is none.
	Dictionary view_snapshot(Object *behaviour, int64_t peer_id);
	Dictionary view_state(Object *behaviour, int64_t peer_id);
	/// The bits DotNetVar.write writes for [param value], begun [param pad] zero bits into a byte:
	/// [bytes, bits]. [param spec] is one declaration from DotNetBehaviour._native_spec.
	Array encode_value(const PackedFloat64Array &spec, const Variant &value, int64_t pad);
	Dictionary describe();
};

} // namespace godot
