// Shader compilation cost of a game on this stack, from a MoltenVK shader dump (MVK_CONFIG_SHADER_DUMP_DIR: each
// shader's SPIR-V and the MSL MoltenVK generated for it, and the shaders of each pipeline). See shaders.sh.
//
// Stages, as MoltenVK runs them for a pipeline:
//   convert   SPIR-V -> MSL with SPIRV-Cross (this build's library, MoltenVK's options: Metal 3 argument buffers,
//             robustness2, texel buffer offsets; bindings from reflection, so the MSL differs in binding details)
//   library   MSL -> MTLLibrary (Metal front end), on the MSL MoltenVK generated, with MoltenVK's compile options
//   pipeline  MTLFunctions -> pipeline state (Metal back end): compute pipelines, and render pipelines of the
//             dumped vertex + fragment pairs (vertex layout and attachment formats derived from the shaders;
//             geometry shader pipelines, which MoltenVK builds as object + mesh pipelines, are not built)
// Cold, like the first run of a game: each MSL source gets a unique comment (--nonce; the front end caches by
// source), and Metal's shader cache of command line tools ($DARWIN_USER_CACHE_DIR/com.apple.metal: the back end's
// cache, keyed by the compiled code, kept across processes; the compiler service also caches in memory for the
// process) is deleted at start. --keep-cache with the nonce of an earlier run measures a warm run (a second run of
// the game; the app's cache lives in its own cache directory). --threads N runs library + pipeline on N threads
// at once (vkd3d-proton creates pipelines on several threads); --summary prints only the wall times. shaders.sh
// runs one process per configuration.
//
//   shaders <dump dir> [--limit N] [--match TEXT] [--threads N] [--math safe|relaxed|fast] [--nonce N]
//                      [--keep-cache] [--summary]
// --match keeps the shaders whose MSL contains TEXT (the dump also holds other MoltenVK users of the VM, e.g. the
// Steam client: --match RootConstants keeps vkd3d-proton's).
#import <Metal/Metal.h>
#include "spirv_msl.hpp"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <dirent.h>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

using namespace SPIRV_CROSS_NAMESPACE;
using Clock = std::chrono::steady_clock;

static double ms_since(Clock::time_point t0)
{
	return std::chrono::duration<double, std::milli>(Clock::now() - t0).count();
}

struct Shader {
	std::string hash, kind;   // kind: vs, fs, cs, gs
	std::vector<uint32_t> spv;
	std::string msl;
	id<MTLLibrary> lib = nil;
	double convert_ms = -1, library_ms = -1;
};

struct Pipeline {
	std::string vs, fs;
	double ms = -1;
};

static std::string read_file(const std::string &path)
{
	std::ifstream f(path, std::ios::binary);
	return std::string((std::istreambuf_iterator<char>(f)), {});
}

// SPIR-V -> MSL with MoltenVK's options and bindings derived from reflection.
static double convert(const Shader &s, std::string &error)
{
	auto t0 = Clock::now();
	try {
		CompilerMSL c(s.spv);
		auto o = c.get_msl_options();
		o.platform = CompilerMSL::Options::macOS;
		o.set_msl_version(3, 2);
		o.argument_buffers = true;
		o.argument_buffers_tier = CompilerMSL::Options::ArgumentBuffersTier::Tier2;
		o.pad_argument_buffer_resources = true;
		o.force_active_argument_buffer_resources = false;
		o.robust_buffer_access2 = true;
		o.robust_image_access2 = true;
		o.add_texture_buffer_offsets = true;
		o.enable_decoration_binding = true;
		if (c.get_execution_model() == spv::ExecutionModelGeometry) {
			o.for_mesh_pipeline = true;
			o.capture_output_to_buffer = false;
		}
		c.set_msl_options(o);
		auto model = c.get_execution_model();
		auto res = c.get_shader_resources();
		std::map<uint32_t, uint32_t> next_index;   // per set
		std::map<std::pair<uint32_t, uint32_t>, bool> seen;
		auto add = [&](const SmallVector<Resource> &list, SPIRType::BaseType basetype) {
			for (auto &r : list) {
				uint32_t set = c.get_decoration(r.id, spv::DecorationDescriptorSet);
				uint32_t binding = c.get_decoration(r.id, spv::DecorationBinding);
				if (seen[{ set, binding }])
					continue;   // aliases share the binding
				seen[{ set, binding }] = true;
				auto &type = c.get_type(r.type_id);
				MSLResourceBinding b;
				b.stage = model;
				b.desc_set = set;
				b.binding = binding;
				b.basetype = basetype;
				b.count = type.array.empty() ? 1 : (type.array[0] ? type.array[0] : 1000000);
				if (!next_index.count(set)) {
					MSLResourceBinding sb;
					sb.stage = model;
					sb.desc_set = set;
					sb.binding = kBufferSizeBufferBinding;
					sb.count = 1;
					sb.basetype = SPIRType::Void;
					c.add_msl_resource_binding(sb);
					next_index[set] = 1;
				}
				b.msl_buffer = b.msl_texture = b.msl_sampler = next_index[set];
				next_index[set] += b.count == 1000000 ? 1 : b.count;
				c.add_msl_resource_binding(b);
			}
		};
		add(res.uniform_buffers, SPIRType::Void);
		add(res.storage_buffers, SPIRType::Void);
		add(res.storage_images, SPIRType::Image);
		add(res.separate_images, SPIRType::Image);
		add(res.separate_samplers, SPIRType::Sampler);
		add(res.sampled_images, SPIRType::SampledImage);
		for (auto &pc : res.push_constant_buffers) {
			(void)pc;
			MSLResourceBinding b;
			b.stage = model;
			b.desc_set = kPushConstDescSet;
			b.binding = kPushConstBinding;
			b.count = 1;
			b.basetype = SPIRType::Void;
			b.msl_buffer = 20;
			c.add_msl_resource_binding(b);
		}
		c.compile();
	} catch (const std::exception &e) {
		error = e.what();
		return -1;
	}
	return ms_since(t0);
}

static MTLCompileOptions *compile_options(const std::string &math, bool invariance)
{
	MTLCompileOptions *o = [MTLCompileOptions new];
	o.languageVersion = MTLLanguageVersion3_2;
	if (math == "fast") {
		o.mathMode = MTLMathModeFast;
		o.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsFast;
	} else if (math == "relaxed") {
		o.mathMode = MTLMathModeRelaxed;
		o.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
	} else {
		o.mathMode = MTLMathModeSafe;   // MoltenVK's choice without SPIR-V fast math flags (vkd3d-proton, DXVK)
		o.mathFloatingPointFunctions = MTLMathFloatingPointFunctionsPrecise;
	}
	o.preserveInvariance = invariance;
	return o;
}

static id<MTLLibrary> compile_library(id<MTLDevice> dev, const Shader &s, const std::string &math, uint64_t nonce,
                                      double &ms)
{
	@autoreleasepool {
		std::string src = s.msl;
		if (nonce)
			src = "// bench " + std::to_string(nonce) + "\n" + src;
		NSString *text = [[NSString alloc] initWithBytes:src.data() length:src.size() encoding:NSUTF8StringEncoding];
		MTLCompileOptions *opts = compile_options(math, s.msl.find("invariant]]") != std::string::npos);
		NSError *err = nil;
		auto t0 = Clock::now();
		id<MTLLibrary> lib = [dev newLibraryWithSource:text options:opts error:&err];
		ms = ms_since(t0);
		return lib;
	}
}

static MTLVertexFormat vertex_format(MTLDataType t)
{
	switch (t) {
	case MTLDataTypeFloat: return MTLVertexFormatFloat;
	case MTLDataTypeFloat2: return MTLVertexFormatFloat2;
	case MTLDataTypeFloat3: return MTLVertexFormatFloat3;
	case MTLDataTypeFloat4: return MTLVertexFormatFloat4;
	case MTLDataTypeHalf: return MTLVertexFormatHalf;
	case MTLDataTypeHalf2: return MTLVertexFormatHalf2;
	case MTLDataTypeHalf3: return MTLVertexFormatHalf3;
	case MTLDataTypeHalf4: return MTLVertexFormatHalf4;
	case MTLDataTypeInt: return MTLVertexFormatInt;
	case MTLDataTypeInt2: return MTLVertexFormatInt2;
	case MTLDataTypeInt3: return MTLVertexFormatInt3;
	case MTLDataTypeInt4: return MTLVertexFormatInt4;
	case MTLDataTypeUInt: return MTLVertexFormatUInt;
	case MTLDataTypeUInt2: return MTLVertexFormatUInt2;
	case MTLDataTypeUInt3: return MTLVertexFormatUInt3;
	case MTLDataTypeUInt4: return MTLVertexFormatUInt4;
	default: return MTLVertexFormatFloat4;
	}
}

// Attachment formats from the fragment shader's output struct: [[color(N)]] members by scalar type, [[depth]].
static void attachments(const std::string &msl, MTLRenderPipelineDescriptor *d)
{
	size_t start = msl.find("struct main0_out");
	if (start == std::string::npos)
		return;
	size_t end = msl.find("};", start);
	std::istringstream lines(msl.substr(start, end - start));
	std::string line;
	while (std::getline(lines, line)) {
		size_t c = line.find("[[color(");
		if (c != std::string::npos) {
			unsigned n = std::stoul(line.substr(c + 8));
			std::string type = line.substr(line.find_first_not_of(" \t"));
			MTLPixelFormat f = MTLPixelFormatRGBA16Float;
			if (type.rfind("uint", 0) == 0) f = MTLPixelFormatRGBA32Uint;
			else if (type.rfind("int", 0) == 0) f = MTLPixelFormatRGBA32Sint;
			else if (type.rfind("ushort", 0) == 0) f = MTLPixelFormatRGBA16Uint;
			else if (type.rfind("short", 0) == 0) f = MTLPixelFormatRGBA16Sint;
			if (n < 8)
				d.colorAttachments[n].pixelFormat = f;
		}
		if (line.find("[[depth(") != std::string::npos)
			d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
	}
}

static double build_pipeline(id<MTLDevice> dev, Shader *vs, Shader *fs, Shader *cs, std::string &error)
{
	@autoreleasepool {
		NSError *err = nil;
		if (cs) {
			id<MTLFunction> f = [cs->lib newFunctionWithName:@"main0"];
			if (!f) { error = "no main0"; return -1; }
			auto t0 = Clock::now();
			id<MTLComputePipelineState> p = [dev newComputePipelineStateWithFunction:f error:&err];
			double ms = ms_since(t0);
			if (!p) { error = err.localizedDescription.UTF8String; return -1; }
			return ms;
		}
		id<MTLFunction> vf = [vs->lib newFunctionWithName:@"main0"];
		id<MTLFunction> ff = fs ? [fs->lib newFunctionWithName:@"main0"] : nil;
		if (!vf || (fs && !ff)) { error = "no main0"; return -1; }
		MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
		d.vertexFunction = vf;
		d.fragmentFunction = ff;
		if (vf.vertexAttributes.count) {
			MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
			NSUInteger offset = 0;
			for (MTLVertexAttribute *a in vf.vertexAttributes) {
				if (!a.active)
					continue;
				vd.attributes[a.attributeIndex].format = vertex_format(a.attributeType);
				vd.attributes[a.attributeIndex].offset = offset;
				vd.attributes[a.attributeIndex].bufferIndex = 30;
				offset += 16;
			}
			vd.layouts[30].stride = std::max<NSUInteger>(offset, 16);
			d.vertexDescriptor = vd;
		}
		if (fs)
			attachments(fs->msl, d);
		else
			d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;   // depth-only pass
		auto t0 = Clock::now();
		id<MTLRenderPipelineState> p = [dev newRenderPipelineStateWithDescriptor:d error:&err];
		double ms = ms_since(t0);
		if (!p) { error = err.localizedDescription.UTF8String; return -1; }
		return ms;
	}
}

// Deletes Metal's shader cache of command line tools, so the back end compiles cold.
static void clear_metal_cache()
{
	char dir[1024];
	if (!confstr(_CS_DARWIN_USER_CACHE_DIR, dir, sizeof(dir)))
		return;
	@autoreleasepool {
		NSString *path = [[NSString stringWithUTF8String:dir] stringByAppendingPathComponent:@"com.apple.metal"];
		[[NSFileManager defaultManager] removeItemAtPath:path error:nil];
	}
}

struct Stats {
	size_t n = 0;
	double total = 0, mean = 0, p50 = 0, p90 = 0, p99 = 0, max = 0;
};

static Stats stats(std::vector<double> v)
{
	Stats s;
	v.erase(std::remove_if(v.begin(), v.end(), [](double x) { return x < 0; }), v.end());
	if (v.empty())
		return s;
	std::sort(v.begin(), v.end());
	s.n = v.size();
	for (double x : v) s.total += x;
	s.mean = s.total / s.n;
	auto pct = [&](double p) { return v[std::min(v.size() - 1, size_t(p * (v.size() - 1) + 0.5))]; };
	s.p50 = pct(0.5);
	s.p90 = pct(0.9);
	s.p99 = pct(0.99);
	s.max = v.back();
	return s;
}

static void row(const char *what, const Stats &s, size_t failed)
{
	printf("%-22s %6zu %9.1f %8.2f %8.2f %8.2f %8.2f %9.1f %7zu\n", what, s.n, s.total / 1000, s.mean, s.p50, s.p90,
	       s.p99, s.max, failed);
}

// Runs f(i) for i in [0, n) on `threads` threads; returns the wall time in ms.
template <typename F>
static double parallel(size_t n, unsigned threads, F f)
{
	std::atomic<size_t> next{ 0 };
	auto t0 = Clock::now();
	std::vector<std::thread> pool;
	for (unsigned t = 0; t < threads; t++)
		pool.emplace_back([&] {
			for (size_t i; (i = next++) < n;)
				f(i);
		});
	for (auto &t : pool)
		t.join();
	return ms_since(t0);
}

int main(int argc, char **argv)
{
	if (argc < 2) {
		fprintf(stderr, "usage: %s <dump dir> [--limit N] [--match TEXT] [--threads N] [--math safe|relaxed|fast] "
		                "[--nonce N] [--keep-cache] [--summary]\n", argv[0]);
		return 2;
	}
	std::string dir = argv[1], math = "safe", match;
	size_t limit = 0;
	bool keep_cache = false, summary = false;
	unsigned threads = 1;
	uint64_t nonce = uint64_t(Clock::now().time_since_epoch().count());
	for (int i = 2; i < argc; i++) {
		std::string a = argv[i];
		if (a == "--limit" && i + 1 < argc) limit = std::stoul(argv[++i]);
		else if (a == "--math" && i + 1 < argc) math = argv[++i];
		else if (a == "--match" && i + 1 < argc) match = argv[++i];
		else if (a == "--threads" && i + 1 < argc) threads = std::stoul(argv[++i]);
		else if (a == "--nonce" && i + 1 < argc) nonce = std::stoull(argv[++i]);
		else if (a == "--keep-cache") keep_cache = true;
		else if (a == "--summary") summary = true;
	}
	if (!keep_cache)
		clear_metal_cache();

	// Shaders: shader-<kind>-<hash>.spv + .metal; pipelines: pipeline-<hash>.txt (" VS: <hash>", " FS: <hash>").
	std::vector<Shader> shaders;
	std::vector<Pipeline> pipelines;
	DIR *d = opendir(dir.c_str());
	if (!d) { perror(dir.c_str()); return 1; }
	std::vector<std::string> names;
	while (dirent *e = readdir(d))
		names.push_back(e->d_name);
	closedir(d);
	std::sort(names.begin(), names.end());
	for (auto &name : names) {
		if (name.rfind("shader-", 0) == 0 && name.size() > 4 && name.compare(name.size() - 4, 4, ".spv") == 0) {
			std::string base = name.substr(0, name.size() - 4);
			std::string msl = read_file(dir + "/" + base + ".metal");
			if (msl.empty() || (!match.empty() && msl.find(match) == std::string::npos))
				continue;
			Shader s;
			s.kind = base.substr(7, 2);
			s.hash = base.substr(10);
			std::string bytes = read_file(dir + "/" + name);
			s.spv.resize(bytes.size() / 4);
			memcpy(s.spv.data(), bytes.data(), s.spv.size() * 4);
			s.msl = std::move(msl);
			shaders.push_back(std::move(s));
		} else if (name.rfind("pipeline-", 0) == 0 && name.rfind("pipeline-gs", 0) != 0) {
			std::istringstream f(read_file(dir + "/" + name));
			Pipeline p;
			for (std::string line; std::getline(f, line);) {
				if (line.find("VS: ") != std::string::npos) p.vs = line.substr(line.find("VS: ") + 4);
				if (line.find("FS: ") != std::string::npos) p.fs = line.substr(line.find("FS: ") + 4);
			}
			if (!p.vs.empty())
				pipelines.push_back(p);
		}
	}
	if (limit && shaders.size() > limit) {
		// Every k-th shader, so each kind keeps its share.
		std::vector<Shader> sample;
		for (size_t i = 0; i < shaders.size(); i++)
			if (i * limit / shaders.size() != (i + 1) * limit / shaders.size())
				sample.push_back(std::move(shaders[i]));
		shaders = std::move(sample);
	}
	std::map<std::string, Shader *> by_hash;
	for (auto &s : shaders)
		by_hash[s.kind + s.hash] = &s;
	pipelines.erase(std::remove_if(pipelines.begin(), pipelines.end(), [&](const Pipeline &p) {
		                return !by_hash.count("vs" + p.vs) || (!p.fs.empty() && !by_hash.count("fs" + p.fs));
	                }),
	                pipelines.end());
	std::map<std::string, size_t> kinds;
	for (auto &s : shaders) kinds[s.kind]++;
	if (!summary) {
		printf("%zu shaders (", shaders.size());
		for (auto &k : kinds) printf("%s %zu ", k.first.c_str(), k.second);
		printf("), %zu vertex+fragment pipelines; math %s\n", pipelines.size(), math.c_str());
	}

	id<MTLDevice> dev = MTLCreateSystemDefaultDevice();

	// convert (single thread)
	size_t convert_failed = 0;
	std::string first_error;
	for (auto &s : shaders) {
		if (summary)
			break;
		std::string err;
		s.convert_ms = convert(s, err);
		if (s.convert_ms < 0) {
			convert_failed++;
			if (first_error.empty()) first_error = s.kind + "-" + s.hash + ": " + err;
		}
	}

	// library + pipeline on `threads` threads
	std::vector<Shader *> computes;
	for (auto &s : shaders)
		if (s.kind == "cs") computes.push_back(&s);
	std::vector<double> pipeline_ms(computes.size() + pipelines.size(), -1);
	size_t library_failed = 0, pipeline_failed = 0;
	std::string library_error, pipeline_error;
	std::mutex m;
	double lib_wall = parallel(shaders.size(), threads, [&](size_t i) {
		double ms;
		id<MTLLibrary> lib = compile_library(dev, shaders[i], math, nonce + i, ms);
		shaders[i].lib = lib;
		shaders[i].library_ms = lib ? ms : -1;
		if (!lib) {
			std::lock_guard<std::mutex> g(m);
			library_failed++;
			if (library_error.empty()) library_error = shaders[i].kind + "-" + shaders[i].hash;
		}
	});
	double pipe_wall = parallel(pipeline_ms.size(), threads, [&](size_t i) {
		std::string err;
		double ms = -1;
		if (i < computes.size()) {
			if (computes[i]->lib) ms = build_pipeline(dev, nullptr, nullptr, computes[i], err);
			else err = "library failed";
		} else {
			auto &p = pipelines[i - computes.size()];
			Shader *vs = by_hash["vs" + p.vs], *fs = p.fs.empty() ? nullptr : by_hash["fs" + p.fs];
			if (vs->lib && (!fs || fs->lib)) ms = build_pipeline(dev, vs, fs, nullptr, err);
			else err = "library failed";
		}
		pipeline_ms[i] = ms;
		if (ms < 0) {
			std::lock_guard<std::mutex> g(m);
			pipeline_failed++;
			if (pipeline_error.empty()) pipeline_error = err;
		}
	});

	const char *label = keep_cache ? "warm" : "cold";
	if (summary) {
		printf("%2u thread%s %s: libraries %7.1f s, pipelines %7.1f s, total %7.1f s\n", threads, threads == 1 ? " " : "s",
		       label, lib_wall / 1000, pipe_wall / 1000, (lib_wall + pipe_wall) / 1000);
		return 0;
	}
	printf("\nper shader / pipeline, %u thread%s, %s (ms)\n", threads, threads == 1 ? "" : "s", label);
	printf("%-22s %6s %9s %8s %8s %8s %8s %9s %7s\n", "stage", "n", "total s", "mean", "p50", "p90", "p99", "max",
	       "failed");
	for (auto &k : kinds) {
		std::vector<double> v;
		size_t failed = 0;
		for (auto &s : shaders)
			if (s.kind == k.first) { v.push_back(s.convert_ms); failed += s.convert_ms < 0; }
		row(("convert " + k.first).c_str(), stats(v), failed);
	}
	for (auto &k : kinds) {
		std::vector<double> v;
		size_t failed = 0;
		for (auto &s : shaders)
			if (s.kind == k.first) { v.push_back(s.library_ms); failed += s.library_ms < 0; }
		row(("library " + k.first).c_str(), stats(v), failed);
	}
	std::vector<double> cp(pipeline_ms.begin(), pipeline_ms.begin() + computes.size());
	std::vector<double> gp(pipeline_ms.begin() + computes.size(), pipeline_ms.end());
	row("pipeline compute", stats(cp), std::count(cp.begin(), cp.end(), -1.0));
	row("pipeline v+f", stats(gp), std::count(gp.begin(), gp.end(), -1.0));

	std::vector<Shader *> slow;
	for (auto &s : shaders) slow.push_back(&s);
	std::sort(slow.begin(), slow.end(), [](Shader *a, Shader *b) { return a->library_ms > b->library_ms; });
	printf("\nslowest MSL compiles: ");
	for (size_t i = 0; i < 5 && i < slow.size(); i++)
		printf("%s-%s %.0f ms (%zu KB MSL)%s", slow[i]->kind.c_str(), slow[i]->hash.c_str(), slow[i]->library_ms,
		       slow[i]->msl.size() / 1024, i < 4 ? ", " : "\n");
	printf("wall: libraries %.1f s, pipelines %.1f s\n", lib_wall / 1000, pipe_wall / 1000);
	if (convert_failed) printf("convert failures: %zu (first: %s)\n", convert_failed, first_error.c_str());
	if (library_failed) printf("library failures: %zu (first: %s)\n", library_failed, library_error.c_str());
	if (pipeline_failed) printf("pipeline failures: %zu (first: %s)\n", pipeline_failed, pipeline_error.c_str());
	return 0;
}
