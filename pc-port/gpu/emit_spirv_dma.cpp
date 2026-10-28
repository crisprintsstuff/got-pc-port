// SPDX-License-Identifier: GPL-2.0-or-later
// WriteConstDynamic (shim opcodes.inc): a dword stored to guest memory through the DMA page table,
// as read_const_dynamic reads one. For buffers whose V# a shader picks at run time
// (gpu/overrides/resource_patching_pass.cpp, LowerDynamicBufferAccess): Ghost of Tsushima's
// gameplay compute shaders b5500bd4 and bdfc491f write their results through such buffers.
// A page the GPU does not hold yet is reported to the fault buffer (by get_bda_pointer) and the
// store is dropped, as a read of it returns 0. An out of range store (enabled false) is dropped,
// as the hardware drops it.
#include "shader_recompiler/backend/spirv/emit_spirv_instructions.h"
#include "shader_recompiler/backend/spirv/spirv_emit_context.h"

namespace Shader::Backend::SPIRV {

void EmitWriteConstDynamic(EmitContext& ctx, Id base, Id offset, Id value, Id enabled) {
    const Id base_lo{ctx.OpUConvert(ctx.U64, ctx.OpCompositeExtract(ctx.U32[1], base, 0))};
    const Id base_hi{ctx.OpUConvert(ctx.U64, ctx.OpCompositeExtract(ctx.U32[1], base, 1))};
    const Id base_addr{
        ctx.OpBitwiseOr(ctx.U64, base_lo, ctx.OpShiftLeftLogical(ctx.U64, base_hi, ctx.ConstU32(32U)))};
    const Id offset_bytes{ctx.OpShiftLeftLogical(ctx.U32[1], offset, ctx.ConstU32(2U))};
    const Id address{ctx.OpIAdd(ctx.U64, base_addr, ctx.OpUConvert(ctx.U64, offset_bytes))};

    const Id store_label{ctx.OpLabel()};
    const Id merge_label{ctx.OpLabel()};
    const Id pointer{ctx.OpFunctionCall(ctx.U64, ctx.get_bda_pointer, address)};
    const Id is_available{
        ctx.OpLogicalAnd(ctx.U1[1], enabled, ctx.OpINotEqual(ctx.U1[1], pointer, ctx.u64_zero_value))};
    ctx.OpSelectionMerge(merge_label, spv::SelectionControlMask::MaskNone);
    ctx.OpBranchConditional(is_available, store_label, merge_label);

    ctx.AddLabel(store_label);
    const Id dword_pointer{ctx.OpConvertUToPtr(ctx.physical_pointer_type_u32, pointer)};
    ctx.OpStore(dword_pointer, value, spv::MemoryAccessMask::Aligned, 4u);
    ctx.OpBranch(merge_label);

    ctx.AddLabel(merge_label);
}

} // namespace Shader::Backend::SPIRV
