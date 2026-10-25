#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/string_name.hpp>
#include <godot_cpp/variant/variant.hpp>

#include <condition_variable>
#include <deque>
#include <memory>
#include <mutex>
#include <thread>
#include <unordered_map>
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
};

struct IdRec {
	uint64_t object_id = 0;
	int64_t net_id = 0;
	int64_t owner = 0;
	bool shared = false;
	uint64_t seen = 0;
	std::vector<BehRec *> behaviours;
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

struct Peer {
	int64_t id = 0;
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
	bool strict = false;
	bool compact = false;
	bool send_lead = false;
	int64_t remaining = 0;
	int64_t lead_x = 0;
	int64_t lead_y = 0;
	godot::Dictionary accumulators;
	godot::Dictionary starved_ticks;
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
	std::mutex _mutex;
	std::condition_variable _work_cv;
	std::condition_variable _done_cv;
	std::vector<std::thread> _threads;
	bool _quit = false;
	int _workers = 0;

	int64_t _last_build_usec = 0;
	int64_t _last_wait_usec = 0;
	int64_t _last_read_usec = 0;
	int64_t _snapshots = 0;
	int64_t _custom_reads = 0;

	dotnet::BehRec *_behaviour_for(Object *behaviour, uint64_t id);
	dotnet::IdRec *_identity_for(const Variant &identity);
	void _adopt(dotnet::BehRec *rec, Object *behaviour);
	void _read(dotnet::BehRec *rec, Object *behaviour);
	void _drop_behaviour(dotnet::BehRec *rec);
	void _sweep();
	void _set_workers(int workers);
	void _worker_loop();
	void _run_job(dotnet::Job *job);
	bool _take_and_run();

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
	/// send_lead, lead.x, lead.y. The budget dictionaries are the peer's own and are written by the build.
	void submit_peer(const Array &relevant, const PackedInt64Array &info, const Dictionary &accumulators, const Dictionary &starved_ticks);
	/// Waits for every queued build and returns one result per peer, in submission order:
	/// [peer_id, payloads, entity counts, starved, spent, split, unchanged_listed, unchanged_saved,
	/// leads_sent, oversize net id or -1, oversize bytes].
	Array finish_snapshot();

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
