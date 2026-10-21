// SPDX-License-Identifier: GPL-2.0
/*
 * Validate RISC-V KVM Vector KVM_GET/SET_ONE_REG interactions while the
 * vCPU repeatedly runs on one physical CPU.
 */
#include <stdio.h>
#include <string.h>

#include "kvm_syscalls.h"
#include "kvm_util.h"
#include "processor.h"
#include "ucall_common.h"

#define MAX_VLENB 256
#define GUEST_PATTERN 0x31
#define SET_PATTERN 0xa7

static unsigned char guest_source[MAX_VLENB] __aligned(64);
static unsigned char guest_after_get[MAX_VLENB] __aligned(64);
static unsigned char guest_after_set[MAX_VLENB] __aligned(64);

static void guest_vector_load(const void *source, unsigned long vlenb)
{
	asm volatile(".option push\n"
		".option arch, +v\n"
		"vsetvli zero, %1, e8, m1, ta, ma\n"
		"vle8.v v0, (%0)\n"
		".option pop\n"
		:
		: "r"(source), "r"(vlenb)
		: "memory");
}

static void guest_vector_store(void *destination, unsigned long vlenb)
{
	asm volatile(".option push\n"
		".option arch, +v\n"
		"vsetvli zero, %1, e8, m1, ta, ma\n"
		"vse8.v v0, (%0)\n"
		".option pop\n"
		:
		: "r"(destination), "r"(vlenb)
		: "memory");
}

static void guest_expect_pattern(const unsigned char *data,
				 unsigned long vlenb, unsigned char pattern)
{
	unsigned long i;

	for (i = 0; i < vlenb; i++)
		GUEST_ASSERT_EQ(data[i], pattern);
}

static void guest_code(void)
{
	unsigned long i, vlenb;

	csr_set(CSR_SSTATUS, SR_VS_INITIAL);
	vlenb = csr_read(CSR_VLENB);
	GUEST_ASSERT(vlenb && vlenb <= MAX_VLENB);

	for (i = 0; i < vlenb; i++)
		guest_source[i] = GUEST_PATTERN;

	guest_vector_load(guest_source, vlenb);
	GUEST_SYNC(1);

	guest_vector_store(guest_after_get, vlenb);
	guest_expect_pattern(guest_after_get, vlenb, GUEST_PATTERN);
	GUEST_SYNC(2);

	guest_vector_store(guest_after_set, vlenb);
	guest_expect_pattern(guest_after_set, vlenb, SET_PATTERN);
	GUEST_DONE();
}

static void pin_to_one_cpu(void)
{
	cpu_set_t allowed, pinned;
	int cpu;

	kvm_sched_getaffinity(0, sizeof(allowed), &allowed);
	for (cpu = 0; cpu < CPU_SETSIZE; cpu++) {
		if (CPU_ISSET(cpu, &allowed))
			break;
	}
	TEST_ASSERT(cpu < CPU_SETSIZE, "no CPU available");

	CPU_ZERO(&pinned);
	CPU_SET(cpu, &pinned);
	kvm_sched_setaffinity(0, sizeof(pinned), &pinned);
}

static void run_to_sync(struct kvm_vcpu *vcpu, unsigned long stage)
{
	struct ucall uc;
	u64 cmd;

	vcpu_run(vcpu);
	cmd = get_ucall(vcpu, &uc);
	if (cmd == UCALL_ABORT)
		REPORT_GUEST_ASSERT(uc);
	TEST_ASSERT_EQ(cmd, UCALL_SYNC);
	TEST_ASSERT_EQ(uc.args[1], stage);
}

static void run_to_done(struct kvm_vcpu *vcpu)
{
	struct ucall uc;
	u64 cmd;

	vcpu_run(vcpu);
	cmd = get_ucall(vcpu, &uc);
	if (cmd == UCALL_ABORT)
		REPORT_GUEST_ASSERT(uc);
	TEST_ASSERT_EQ(cmd, UCALL_DONE);
}

static int set_one_reg_buffer(struct kvm_vcpu *vcpu, u64 id, void *buffer)
{
	struct kvm_one_reg reg = {
		.id = id,
		.addr = (u64)buffer,
	};

	return __vcpu_ioctl(vcpu, KVM_SET_ONE_REG, &reg);
}

static void expect_pattern(const unsigned char *data, unsigned long length,
			   unsigned char pattern, const char *where)
{
	unsigned long i;

	for (i = 0; i < length; i++)
		TEST_ASSERT(data[i] == pattern,
			    "%s byte %lu: got %#x, expected %#x",
			    where, i, data[i], pattern);
}

int main(void)
{
	unsigned char get_buffer[MAX_VLENB] __aligned(64) = {};
	unsigned char set_buffer[MAX_VLENB] __aligned(64);
	struct kvm_vm *vm;
	struct kvm_vcpu *vcpu;
	unsigned long vlenb;
	u64 vlenb_id, v0_id, size;
	int ret;

	pin_to_one_cpu();
	vm = vm_create_with_one_vcpu(&vcpu, guest_code);
	TEST_REQUIRE(__vcpu_has_isa_ext(vcpu, KVM_RISCV_ISA_EXT_V));

	vm_init_vector_tables(vm);
	vcpu_init_vector_tables(vcpu);

	vlenb_id = KVM_REG_RISCV | KVM_REG_RISCV_VECTOR |
		KVM_REG_SIZE_ULONG | KVM_REG_RISCV_VECTOR_CSR_REG(vlenb);
	ret = __vcpu_get_reg(vcpu, vlenb_id, &vlenb);
	TEST_ASSERT(!ret, "KVM_GET_ONE_REG(vlenb) failed: %d", ret);
	TEST_ASSERT(vlenb && vlenb <= MAX_VLENB && !(vlenb & (vlenb - 1)),
		    "unsupported vlenb: %lu", vlenb);

	size = (u64)__builtin_ctzl(vlenb) << KVM_REG_SIZE_SHIFT;
	v0_id = KVM_REG_RISCV | KVM_REG_RISCV_VECTOR | size |
		KVM_REG_RISCV_VECTOR_REG(0);

	run_to_sync(vcpu, 1);
	ret = __vcpu_get_reg(vcpu, v0_id, get_buffer);
	TEST_ASSERT(!ret, "KVM_GET_ONE_REG(v0) failed: %d", ret);
	expect_pattern(get_buffer, vlenb, GUEST_PATTERN, "GET v0");

	run_to_sync(vcpu, 2);
	memset(set_buffer, SET_PATTERN, vlenb);
	ret = set_one_reg_buffer(vcpu, v0_id, set_buffer);
	TEST_ASSERT(!ret, "KVM_SET_ONE_REG(v0) failed: %d", ret);

	run_to_done(vcpu);
	sync_global_from_guest(vm, guest_after_get);
	sync_global_from_guest(vm, guest_after_set);
	expect_pattern(guest_after_get, vlenb, GUEST_PATTERN,
		       "guest after GET");
	expect_pattern(guest_after_set, vlenb, SET_PATTERN,
		       "guest after SET");

	pr_info("Vector ONE_REG owner test passed (vlenb=%lu)\n", vlenb);
	kvm_vm_free(vm);
	return 0;
}
