//
// Copyright (C) 2014 Jeff Bush
// 
// This library is free software; you can redistribute it and/or
// modify it under the terms of the GNU Library General Public
// License as published by the Free Software Foundation; either
// version 2 of the License, or (at your option) any later version.
// 
// This library is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
// Library General Public License for more details.
// 
// You should have received a copy of the GNU Library General Public
// License along with this library; if not, write to the
// Free Software Foundation, Inc., 51 Franklin St, Fifth Floor,
// Boston, MA  02110-1301, USA.
//

`include "defines.v"

//
// Instruction Pipeline - Instruction Fetch Tag Stage
// - Select a program counter to fetch a thread for
// - Query instruction cache tag memory to determine if the cache line is resident
//

module ifetch_tag_stage(
	input                               clk,
	input                               reset,
	
	// To instruction fetch data stage
	output logic                        ift_instruction_requested,
	output l1i_addr_t                   ift_pc,
	output thread_idx_t                 ift_thread_idx,
	output l1i_tag_t                    ift_tag[`L1I_WAYS],
	output logic                        ift_valid[`L1I_WAYS],
	output logic[2:0]                   ift_lru_flags,

	// from instruction fetch data stage
	input                               ifd_update_lru_en,
	input [2:0]                         ifd_update_lru_flags,
	input l1d_set_idx_t                 ifd_update_lru_set,
	input                               ifd_cache_miss,
	input                               ifd_near_miss,
	input thread_idx_t                  ifd_cache_miss_thread_idx,

	// From ring controller
	input [`L1I_WAYS - 1:0]             rc_itag_update_en_oh,
	input l1i_set_idx_t                 rc_itag_update_set,
	input l1i_tag_t                     rc_itag_update_tag,
	input                               rc_itag_update_valid,
	input                               rc_ilru_read_en,
	input l1i_set_idx_t                 rc_ilru_read_set,
	input [`THREADS_PER_CORE - 1:0]     rc_icache_wake_oh,
	output l1i_way_idx_t                ift_lru,

	// From writeback stage
	input                               wb_rollback_en,
	input thread_idx_t                  wb_rollback_thread_idx,
	input scalar_t                      wb_rollback_pc,

	// From thread select stage
	input [`THREADS_PER_CORE - 1:0]     ts_fetch_en);

	scalar_t program_counter_ff[`THREADS_PER_CORE];
	scalar_t program_counter_nxt[`THREADS_PER_CORE];
	thread_idx_t selected_thread_idx;
	l1i_addr_t pc_to_fetch;
	scalar_t next_pc;
	logic[`THREADS_PER_CORE - 1:0] can_fetch_thread_bitmap;
	logic[`THREADS_PER_CORE - 1:0] selected_thread_oh;
	logic[`THREADS_PER_CORE - 1:0] last_selected_thread_oh;
	logic[`THREADS_PER_CORE - 1:0] icache_wait_threads;
	logic[`THREADS_PER_CORE - 1:0] icache_wait_threads_nxt;
	logic[`THREADS_PER_CORE - 1:0] cache_miss_thread_oh;
	logic[`THREADS_PER_CORE - 1:0] thread_sleep_mask_oh;
	logic[2:0] lru_flags;

	//
	// Pick which thread to fetch next.
	//
	assign can_fetch_thread_bitmap = ts_fetch_en & ~icache_wait_threads & ~thread_sleep_mask_oh;

	arbiter #(.NUM_ENTRIES(`THREADS_PER_CORE)) thread_select_arbiter(
		.request(can_fetch_thread_bitmap),
		.update_lru(1'b1),
		.grant_oh(selected_thread_oh),
		.*);

	one_hot_to_index #(.NUM_SIGNALS(`THREADS_PER_CORE)) thread_oh_to_idx(
		.one_hot(selected_thread_oh),
		.index(selected_thread_idx));

	//
	// Update program counters
	// This is a bit subtle. If the last cycle was a cache hit, program_counter_ff points 
	// to the instruction that was just fetched.  If a cache miss occurred, it points to 
	// the next instruction that should be fetched. The next instruction address--be it a 
	// branch or the next sequential instruction--is always resolved in the next cycle after 
	// the address is issued, regardless of whether a cache hit or miss occurred.
	//
	genvar thread_idx;
	generate
		for (thread_idx = 0; thread_idx < `THREADS_PER_CORE; thread_idx++)
		begin : thread_logic
			always_comb
			begin
				if (wb_rollback_en && wb_rollback_thread_idx == thread_idx)
					program_counter_nxt[thread_idx] = wb_rollback_pc;
				else if (ift_instruction_requested && !ifd_cache_miss && !ifd_near_miss 
					&& last_selected_thread_oh[thread_idx])
					program_counter_nxt[thread_idx] = program_counter_ff[thread_idx] + 4;
				else
					program_counter_nxt[thread_idx] = program_counter_ff[thread_idx];
			end
		end
	endgenerate

	assign pc_to_fetch = program_counter_nxt[selected_thread_idx];

	//
	// Cache way metadata
	//
	genvar way_idx;
	generate
		for (way_idx = 0; way_idx < `L1I_WAYS; way_idx++)
		begin : way_tags
			logic line_valid[`L1I_SETS];

			sram_1r1w #(.DATA_WIDTH($bits(l1i_tag_t)), .SIZE(`L1I_SETS)) tag_ram(
				.read_en(|can_fetch_thread_bitmap),
				.read_addr(pc_to_fetch.set_idx),
				.read_data(ift_tag[way_idx]),
				.write_en(rc_itag_update_en_oh[way_idx]),
				.write_addr(rc_itag_update_set),
				.write_data(rc_itag_update_tag),
				.*);

			always_ff @(posedge clk, posedge reset)
			begin
				if (reset)
				begin
					for (int set_idx = 0; set_idx < `L1I_SETS; set_idx++)
						line_valid[set_idx] <= 0;
				end
				else 
				begin
					if (rc_itag_update_en_oh[way_idx])
						line_valid[rc_itag_update_set] <= rc_itag_update_valid;
					
					// Fetch cache line state for pipeline
					if (can_fetch_thread_bitmap != 0)
					begin
						if (rc_itag_update_en_oh[way_idx] && rc_itag_update_set == pc_to_fetch.set_idx)
							ift_valid[way_idx] <= rc_itag_update_valid;	// Bypass
						else
							ift_valid[way_idx] <= line_valid[pc_to_fetch.set_idx];
					end
				end
			end
		end
	endgenerate

	// Pseudo-LRU.  Explanation of basic algorithm in dcache_data_stage.  The bits stored
	//  here encode the order of ways for each set as a binary tree.
	sram_2r1w #(.DATA_WIDTH(3), .SIZE(`L1D_SETS)) lru_data(
		// Read port 1: fetches existing LRU flags, which will be used to update the LRU.  
		// - If a new cache line is being pushed into the cache, we will move that line to 
		//   the LRU (thus we must fetch the old LRU bits here).  Otherwise,
		// - If there is a cache hit, move that line to the MRU.
		.read1_en(|can_fetch_thread_bitmap || |rc_itag_update_en_oh),
		.read1_addr(|rc_itag_update_en_oh ? rc_itag_update_set : pc_to_fetch.set_idx),
		.read1_data(ift_lru_flags),

		// Read port 2: Used by ring controller to determine which way should be filled.  
		// This is accessed one cycle before tag memory is updated.
		.read2_en(rc_ilru_read_en),	// From ring controller
		.read2_addr(rc_ilru_read_set),
		.read2_data(lru_flags),

		// Update LRU (from next stage)
		.write_en(ifd_update_lru_en),
		.write_addr(ifd_update_lru_set),
		.write_data(ifd_update_lru_flags),
		.write_byte_en(0),	// Unused
		.*);

	always_comb
	begin
		casez (lru_flags)
			3'b00?: ift_lru = 0;
			3'b10?: ift_lru = 1;
			3'b?10: ift_lru = 2;
			3'b?11: ift_lru = 3;
		endcase
	end

	// 
	// Track which threads are waiting on instruction cache misses.  Avoid trying to 
	// fetch them from the instruction cache until their misses are fulfilled.
	// Note that there is no cancelling pending instruction cache misses.  If a thread 
	// faults on a miss and then is rolled back, it must still wait for that miss to be 
	// filled before restarting (othewise a race condition could exist when the response
	// came in for the original request)
	//
	index_to_one_hot #(.NUM_SIGNALS(`THREADS_PER_CORE)) convert_miss_idx(
		.one_hot(cache_miss_thread_oh),
		.index(ifd_cache_miss_thread_idx));

	assign thread_sleep_mask_oh = cache_miss_thread_oh & {`THREADS_PER_CORE{ifd_cache_miss}};
	assign icache_wait_threads_nxt = (icache_wait_threads | thread_sleep_mask_oh) & ~rc_icache_wake_oh;

	always_ff @(posedge clk, posedge reset)
	begin
		if (reset)
		begin
			for (int i = 0; i < `THREADS_PER_CORE; i++)
				program_counter_ff[i] <= 0;
		
			/*AUTORESET*/
			// Beginning of autoreset for uninitialized flops
			icache_wait_threads <= {(1+(`THREADS_PER_CORE-1)){1'b0}};
			ift_instruction_requested <= 1'h0;
			ift_pc <= 1'h0;
			ift_thread_idx <= 1'h0;
			last_selected_thread_oh <= {(1+(`THREADS_PER_CORE-1)){1'b0}};
			// End of automatics
		end
		else
		begin
			icache_wait_threads <= icache_wait_threads_nxt;
			ift_pc <= pc_to_fetch;
			ift_thread_idx <= selected_thread_idx;
			for (int i = 0; i < `THREADS_PER_CORE; i++)
				program_counter_ff[i] <= program_counter_nxt[i];			

			ift_instruction_requested <= |can_fetch_thread_bitmap;	
			last_selected_thread_oh <= selected_thread_oh;
			if (wb_rollback_en && (wb_rollback_pc == 0 || wb_rollback_pc[1:0] != 0))
			begin
				$display("thread %d rolled back to bad address %x", wb_rollback_thread_idx,
					wb_rollback_pc);
				$finish;
			end
		end
	end
endmodule

// Local Variables:
// verilog-typedef-regexp:"_t$"
// End:

