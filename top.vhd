-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.types_pkg.all;
use work.params_pkg.all;
use work.reduce_pkg.all;

-- top component for CRYSTALS-Kyber and CRYSTALS-Dilithium
entity top is
generic (
    SIMULATION: boolean := false
);
port (
    clk: in std_logic;
    rst: in std_logic;

    -- 776b for `sec_conversion`
    sec_conversion_random: in std_logic_vector(775 downto 0);
    -- 0 - a2b => Z_2^k, 1 -> b2a => Z_q
    sec_conversion_random_mode: out std_logic;
    -- 25b for remaining components (`sample`, `sec_decompose`, `sec_decompressed_comparison`)
    -- this is shared among them, as they will never run at the same time
    other_random: in std_logic_vector(24 downto 0);

    -- 10 downto 9 determines security level:
    -- - 00 - kyber 2, dilithium 2
    -- - 01 - kyber 3, dilithium 3
    -- - 10 - kyber 4, dilithium 5
    -- 8 downto 0 determines mode:
    -- - 000000001 - kyber - CPAPKE KeyGen
    -- - 000000010 - kyber - CPAPKE Enc
    -- - 000000100 - kyber - CPAPKE Dec
    -- - 000001000 - kyber - CCAKEM KeyGen
    -- - 000010000 - kyber - CCAKEM Enc
    -- - 000100000 - kyber - CCAKEM Dec
    -- - 001000000 - dilithium - KeyGen
    -- - 010000000 - dilithium - Sign
    -- - 100000000 - dilithium - Verify
    component_mode: in std_logic_vector(10 downto 0);
    component_mode_vld: in std_logic;
    component_mode_next: out std_logic;

    s_axis_tdata: in slv_array_t(1 downto 0)(63 downto 0);
    s_axis_tlast: in std_logic;
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    m_axis_tdata: out slv_array_t(1 downto 0)(63 downto 0);
    m_axis_tlast: out std_logic;
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of top is
    -- constants
    constant BRAM_DELAY: natural := 2;

    -- signals for basic info
    signal param_k: natural range 2 to 8;
    signal param_l: natural range 4 to 7;
    signal is_dilithium: std_logic;

    -- signals for current mode
    signal mode: std_logic_vector(10 downto 0);
    signal mode_vld: std_logic;

    signal running: std_logic;

    -- LUTRAM storing all the needed values, that are not coefficients
    -- dilithium - key_gen:
    -- - 3 downto 0 => seed -> rho
    -- - 15 downto 8 => tr
    -- - 23 downto 16 => rho'
    -- - 27 downto 24 => K
    -- dilithium - sign:
    -- - 3 downto 0 => rho
    -- - 7 downto 4 => K
    -- - 15 downto 8 => tr -> mu
    -- - 23 downto 16 => rnd -> rho'
    -- - 31 downto 24 => c
    -- dilithium - verify:
    -- - 3 downto 0 => rho
    -- - 15 downto 8 => tr -> mu
    -- - 31 downto 24 => c
    -- kyber - pke_key_gen:
    -- - 3 downto 0 => seed -> rho
    -- - 19 downto 16 => sigma
    -- kyber - kem_key_gen (same as pke_key_gen +):
    -- - 11 downto 8 => H(pk)
    -- - 15 downto 12 => z
    -- kyber - pke_enc:
    -- - 3 downto 0 => rho
    -- - 19 downto 16 => r
    -- kyber - kem_enc (same as pke_enc +):
    -- - 11 downto 8 => H(pk)
    -- - 15 downto 12 => z -> K
    -- kyber - kem_dec (same as kem_enc +):
    -- - 19 downto 16 => m -> r
    -- - 31 downto 28 => K_ (shared key for implicit rejection)
    -- - `data_1` => masked share of the corresponding memory if value is masked
    signal data_0, data_1: slv_array_t(31 downto 0)(63 downto 0) := (others => (others => '0'));
    -- accessing the data to infer LUTRAM correctly
    signal current_data: slv_array_t(1 downto 0)(63 downto 0);
    -- signals indicating data is valid
    -- `seed_vld` - seed for key_gen valid
    -- `seeds_vld` - during key_gen output from hash of seed is valid, during sign rho' is valid, during enc, dec r is valid
    -- `tr_vld` - H(pk) valid
    -- `c_vld` - challenge valid
    -- `mu_vld` - H(tr || msg) valid, decoded message during kyber is valid
    signal seed_vld, seeds_vld, tr_vld, c_vld, mu_vld: std_logic;

    -- counters added to seeds that are hashed during polynomial samplings
    -- used for matrix sampling (i for row, j for column)
    signal count_i, count_j: unsigned(7 downto 0);
    -- used for vectors sampling
    signal count_k: unsigned(15 downto 0);

    -- decode signals
    signal decode_s_axis_tdata: slv_array_t(1 downto 0)(63 downto 0);
    signal decode_s_axis_tuser: std_logic_vector(3 downto 0);
    signal decode_s_axis_tvalid: std_logic;
    signal decode_s_axis_tready: std_logic_vector(1 downto 0);

    signal decode_m_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal decode_m_axis_tuser: slv_array_t(1 downto 0)(3 downto 0);
    signal decode_m_axis_tvalid: std_logic_vector(1 downto 0);
    signal decode_m_axis_tready: std_logic;

    signal decode_m_axis_shares_tdata_r: slv_array_t(1 downto 0)(95 downto 0);
    signal decode_m_axis_shares_tuser_r: std_logic_vector(3 downto 0);
    signal decode_m_axis_shares_tvalid_r: std_logic;

    -- encode signals
    signal encode_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal encode_s_axis_tuser: std_logic_vector(3 downto 0);
    signal encode_s_axis_tvalid: std_logic;
    signal encode_s_axis_tready: std_logic_vector(1 downto 0);

    signal encode_m_axis_tdata: slv_array_t(1 downto 0)(63 downto 0);
    signal encode_m_axis_tvalid: std_logic_vector(1 downto 0);
    signal encode_m_axis_tready: std_logic;

    -- unmask signals
    signal unmasked_coeffs_in_r: slv_array_t(1 downto 0)(95 downto 0);
    signal unmasked_coeffs_in_mode_r: std_logic;
    signal unmasked_coeffs_in_vld_r: std_logic;
    signal unmasked_coeffs: std_logic_vector(95 downto 0);
    signal unmasked_coeffs_vld, unmasked_coeffs_next: std_logic;

    signal unmask_mode_reg: std_logic;

    -- mask conversion signals
    signal sec_conversion_bound_check_mode: std_logic_vector(3 downto 0);

    signal sec_conversion_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_conversion_s_axis_tuser: std_logic_vector(3 downto 0);
    signal sec_conversion_s_axis_tvalid, sec_conversion_s_axis_tready: std_logic;

    signal sec_conversion_m_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_conversion_m_axis_tuser: std_logic_vector(3 downto 0);
    signal sec_conversion_m_axis_tvalid, sec_conversion_m_axis_tready: std_logic;

    signal sec_conversion_mode_in, sec_conversion_mode_out: std_logic_vector(3 downto 0);

    -- TODO: make this some better way
    -- after masking dilithium secret key, there must happen subtraction of value based on current mode, that was happening in `compress`
    signal sec_conversion_m_axis_tdata_modified: slv_array_t(1 downto 0)(95 downto 0);

    signal sec_conversion_pending_transactions: natural range 0 to 127;
    signal sec_conversion_has_pending_transactions: std_logic;

    -- masked decoder signals
    signal sec_decoder_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_decoder_s_axis_tvalid, sec_decoder_s_axis_tready: std_logic;

    signal sec_decoder_m_axis_tdata: slv_array_t(1 downto 0)(7 downto 0);
    signal sec_decoder_m_axis_tvalid, sec_decoder_m_axis_tready: std_logic;

    signal sec_decoder_transactions_count: natural range 0 to 31;

    signal sec_decoder_conversion_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_decoder_conversion_s_axis_tvalid, sec_decoder_conversion_s_axis_tready: std_logic;

    signal sec_decoder_conversion_m_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_decoder_conversion_m_axis_tvalid, sec_decoder_conversion_m_axis_tready: std_logic;

    -- masked decompose signals
    signal sec_decompose_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_decompose_s_axis_tuser: std_logic;
    signal sec_decompose_s_axis_tvalid, sec_decompose_s_axis_tready: std_logic;

    signal sec_decompose_m_axis_tdata: std_logic_vector(23 downto 0);
    signal sec_decompose_m_axis_low_bits_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_decompose_m_axis_tvalid, sec_decompose_m_axis_tready: std_logic;

    signal sec_decompose_conversion_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_decompose_conversion_s_axis_tuser: std_logic_vector(3 downto 0);
    signal sec_decompose_conversion_s_axis_tvalid, sec_decompose_conversion_s_axis_tready: std_logic;

    signal sec_decompose_conversion_m_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_decompose_conversion_m_axis_tvalid, sec_decompose_conversion_m_axis_tready: std_logic;

    -- compress signals
    signal compress_s_axis_tdata: std_logic_vector(95 downto 0);
    signal compress_s_axis_tuser: std_logic_vector(5 downto 0);
    signal compress_s_axis_tvalid, compress_s_axis_tready: std_logic;

    signal compress_m_axis_tdata, compress_m_axis_low_bits_tdata: std_logic_vector(95 downto 0);
    signal compress_m_axis_tuser: std_logic_vector(5 downto 0);
    signal compress_m_axis_tvalid, compress_m_axis_tready: std_logic;

    signal compress_mode_compress, compress_mode_decompress, compress_mode_high_bits, compress_mode_low_bits: std_logic;

    -- keccak signals
    signal keccak_read_all: std_logic;

    signal keccak_s_axis_tdata: slv_array_t(1 downto 0)(63 downto 0);
    signal keccak_s_axis_tuser: std_logic_vector(1 downto 0);
    signal keccak_s_axis_tlast, keccak_s_axis_tvalid, keccak_s_axis_tready: std_logic;

    signal keccak_m_axis_tdata: slv_array_t(1 downto 0)(63 downto 0);
    signal keccak_m_axis_tvalid, keccak_m_axis_tready: std_logic;

    signal keccak_first_transaction: std_logic;

    signal keccak_mode_in, keccak_mode_out: std_logic_vector(3 downto 0);
    -- indicates what is used as input to `keccak`
    -- 001 - `data`
    -- 010 - `s_axis_tdata`
    -- 100 - `encode_m_axis_tdata`
    signal keccak_source: std_logic_vector(2 downto 0);
    signal keccak_source_vld: std_logic;
    -- indicates last valid data were fed to keccak, however it is not last transaction as the data need to be padded based on used hash function
    signal keccak_last_absorbing_iteration: std_logic;
    signal keccak_transactions_count, keccak_transactions_count_last: natural range 0 to 20;
    signal keccak_transactions_last: std_logic;

    -- helper counter for hashing of w1
    signal keccak_in_transactions_count, keccak_in_transactions_count_last: natural range 0 to 323;
    signal keccak_in_transactions_last: std_logic;

    -- keccak output is 1088b or 1344b and we read it in 64b transactions, so we need to keep track of it
    signal keccak_out_transactions_count, keccak_out_transactions_count_last: natural range 0 to 79;
    signal keccak_out_transactions_last: std_logic;

    signal keccak_out_transactions_count_last_y: natural range 70 to 79;

    -- sample signals
    signal sample_s_axis_tdata: slv_array_t(1 downto 0)(63 downto 0);
    signal sample_s_axis_tuser: std_logic_vector(2 downto 0);
    signal sample_s_axis_tvalid, sample_s_axis_tready: std_logic;

    signal sample_m_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sample_m_axis_tuser: std_logic_vector(2 downto 0);
    signal sample_m_axis_tlast, sample_m_axis_tvalid, sample_m_axis_tready: std_logic;

    signal sec_sample_bounded_mode: std_logic;

    signal sample_conversion_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sample_conversion_s_axis_tuser: std_logic_vector(3 downto 0);
    signal sample_conversion_s_axis_tvalid, sample_conversion_s_axis_tready: std_logic;

    signal sample_conversion_m_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sample_conversion_m_axis_tuser: std_logic_vector(3 downto 0);
    signal sample_conversion_m_axis_tvalid, sample_conversion_m_axis_tready: std_logic;

    -- sample_in_ball signals
    signal sample_in_ball_data_in: std_logic_vector(7 downto 0);
    signal sample_in_ball_data_in_vld: std_logic;

    signal sample_in_ball_m_axis_tdata: std_logic_vector(95 downto 0);
    signal sample_in_ball_m_axis_tvalid, sample_in_ball_m_axis_tready: std_logic;

    -- keccak is read out in 64b transactions, but we need only 8b transactions for `sample_in_ball`
    signal sample_in_ball_transactions_count: natural range 0 to 7;
    signal sample_in_ball_transactions_last: std_logic;

    -- poly multiplication signals
    signal poly_mul_start, poly_mul_rdy, poly_mul_vld: std_logic;
    signal poly_mul_mode: std_logic_vector(2 downto 0);
    signal poly_mul_coeffs_fifo0_mode_in, poly_mul_coeffs_fifo0_mode_out: std_logic_vector(2 downto 0);

    signal poly_mul_first_iteration, poly_mul_last_iteration: std_logic;

    signal poly_mul_inplace_coeffs: slv_array_t(1 downto 0)(95 downto 0);
    signal poly_mul_inplace_op: std_logic_vector(1 downto 0);
    signal poly_mul_inplace_next: std_logic;

    signal poly_mul_coeffs_wea: std_logic;
    signal poly_mul_coeffs_dina, poly_mul_coeffs_doutb: slv_array_t(1 downto 0)(95 downto 0);
    signal poly_mul_coeffs_addra, poly_mul_coeffs_addrb: std_logic_vector(6 downto 0);

    -- for dilithium last address is 63 and switching is done between 0-63 and 64-127
    -- for kyber last address is 31 and switching is done between 0-31 and 32-63
    signal poly_mul_coeffs_addra_last, poly_mul_coeffs_addra_mux: std_logic;
    signal poly_mul_coeffs_addrb_mux: std_logic;

    -- polynomial multiplication might read from `bram0` or `bram1` this is indicated by following muxes
    signal poly_mul_bram_mux, poly_mul_bram_mux_reg: std_logic;
    signal poly_mul_read_bram_mux: std_logic;
    -- to compensate BRAM_DELAY
    signal poly_mul_coeffs_read_bram_mux_shift_reg: std_logic_vector(BRAM_DELAY - 1 downto 0);

    signal poly_mul_next_bound_check_mode, poly_mul_bound_check_mode: std_logic_vector(1 downto 0);

    signal poly_mul_first_bram_only: std_logic;
    signal poly_mul_repeat_read: std_logic;

    signal poly_mul_has_shares, poly_mul_has_shares_reg: std_logic_vector(1 downto 0);
    signal poly_mul_share_shift_reg: std_logic_vector(BRAM_DELAY - 1 downto 0);

    signal poly_mul_offset_we: std_logic_vector(1 downto 0);
    signal poly_mul_addra_offset0, poly_mul_addra_offset1: std_logic_vector(5 downto 0);
    signal poly_mul_addrb_offset0, poly_mul_addrb_offset1: std_logic_vector(5 downto 0);

    signal poly_mul_running, poly_mul_half, poly_mul_half_finished, poly_mul_finished: std_logic;

    -- bram 0 signals
    signal bram0_wea, bram0_reb: std_logic;
    signal bram0_dina, bram0_doutb: slv_array_t(1 downto 0)(95 downto 0);
    signal bram0_addra, bram0_addra_reg, bram0_addrb: std_logic_vector(8 downto 0);
    signal bram0_dina_ser, bram0_doutb_ser: std_logic_vector(191 downto 0);

    -- for dilithium last address is 63, for kyber last address is 31
    signal bram0_addra_reg_last, bram0_addrb_last: std_logic;

    signal bram0_addrb_offset: std_logic_vector(3 downto 0);

    -- dilithium uses every second bit as it needs double the memory for storing coefficients
    signal bram0_polys_vld: std_logic_vector(15 downto 0);
    signal bram0_can_write: std_logic;

    -- only sometimes the output of conversion should be passed to bram0
    signal bram0_storing_s1s2, bram0_storing_y: std_logic;

    -- bram 1 signals
    signal bram1_wea, bram1_reb: std_logic;
    signal bram1_dina, bram1_doutb: slv_array_t(1 downto 0)(95 downto 0);
    signal bram1_addra, bram1_addrb: std_logic_vector(11 downto 0);
    signal bram1_addrb_reg: std_logic_vector(5 downto 0);
    signal bram1_dina_ser, bram1_doutb_ser: std_logic_vector(191 downto 0);

    -- for dilithium last address is 63, for kyber last address is 31
    signal bram1_addra_reg_kyber_last, bram1_addrb_reg_last, bram1_addrb_reg_second_to_last: std_logic;

    -- used when we want to store same values in `bram1` as in `bram0` (e.g. s1, s2 during dilithium key_gen)
    signal bram1_copy_bram0: std_logic;
    -- used when we want to store values in `bram1` instead of `bram0` (e.g. s during kyber pke_dec)
    signal bram1_take_bram0: std_logic;
    -- indicates keys was loaded to bram1 during kyber pke_dec and kem_dec
    signal bram1_stored_kyber_s, bram1_stored_kyber_t, bram1_stored_kyber_m: std_logic;
    signal bram1_store_kyber_s, bram1_store_kyber_t, bram1_store_kyber_m: std_logic;

    signal bram1_addra_reg: std_logic_vector(11 downto 0);

    signal bram1_mode: std_logic_vector(3 downto 0);
    signal bram1_addrb_offset: std_logic_vector(5 downto 0);

    signal bram1_reading_vld: std_logic;

    -- to compensate BRAM_DELAY
    signal bram1_mode_shift_reg: slv_array_t(BRAM_DELAY - 1 downto 0)(3 downto 0);

    -- small fifo for coefficients
    -- TODO: check this, it does not seem to be right
    -- 0000 - inplace addition/subtraction
    -- 0001 - w high bits
    -- 0010 - w - cs2 low bits
    -- 0011 - z compression
    signal coeffs_fifo0_mode_din, coeffs_fifo0_mode_dout: std_logic_vector(3 downto 0);
    signal coeffs_fifo0_high_bits_din, coeffs_fifo0_high_bits_dout: std_logic_vector(23 downto 0);
    signal coeffs_fifo0_din, coeffs_fifo0_dout: slv_array_t(1 downto 0)(95 downto 0);
    signal coeffs_fifo0_din_vld, coeffs_fifo0_dout_vld, coeffs_fifo0_dout_rdy: std_logic;
    signal coeffs_fifo0_din_ser, coeffs_fifo0_dout_ser: std_logic_vector(219 downto 0);

    -- to compensate BRAM_DELAY
    signal coeffs_fifo0_vld: std_logic_vector(BRAM_DELAY - 1 downto 0);

    -- bigger fifo for ciphertext checks, and polynomials for secure computations
    signal coeffs_fifo1_mode_din, coeffs_fifo1_mode_dout: std_logic_vector(1 downto 0);
    signal coeffs_fifo1_din, coeffs_fifo1_dout: slv_array_t(1 downto 0)(95 downto 0);
    signal coeffs_fifo1_din_vld, coeffs_fifo1_dout_vld, coeffs_fifo1_dout_rdy: std_logic;
    signal coeffs_fifo1_din_ser, coeffs_fifo1_dout_ser: std_logic_vector(193 downto 0);

    signal sec_decompressed_comparison_conversion_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_decompressed_comparison_conversion_s_axis_tvalid, sec_decompressed_comparison_conversion_s_axis_tready: std_logic;

    signal sec_decompressed_comparison_conversion_m_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_decompressed_comparison_conversion_m_axis_tvalid: std_logic;

    signal sec_decompressed_comparison_re_encrypted: std_logic;

    signal sec_decompressed_comparison_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_decompressed_comparison_s_axis_tvalid, sec_decompressed_comparison_s_axis_tready: std_logic;

    signal sec_decompressed_comparison_invalid, sec_decompressed_comparison_invalid_vld: std_logic;

    signal cipher_eq, cipher_eq_vld: std_logic;

    -- bound check signals
    signal bound_check_coeffs_vld: std_logic;
    signal bound_check_in_bound, bound_check_in_bound_vld: std_logic;

    -- masked bound check signals
    signal sec_bound_check_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_bound_check_s_axis_tuser: std_logic_vector(3 downto 0);
    signal sec_bound_check_s_axis_tvalid, sec_bound_check_s_axis_tready: std_logic;

    signal sec_bound_check_invalid, sec_bound_check_invalid_vld: std_logic;

    signal sec_bound_check_conversion_bound_check_mode: std_logic_vector(3 downto 0);

    signal sec_bound_check_conversion_s_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_bound_check_conversion_s_axis_tvalid, sec_bound_check_conversion_s_axis_tready: std_logic;

    signal sec_bound_check_conversion_m_axis_tdata: slv_array_t(1 downto 0)(95 downto 0);
    signal sec_bound_check_conversion_m_axis_tvalid: std_logic;

    -- make_hint signals
    signal make_hint_coeffs_high_bits: std_logic_vector(23 downto 0);
    signal make_hint_coeffs: std_logic_vector(95 downto 0);
    signal make_hint_coeffs_vld: std_logic;

    signal make_hint_coeffs_arr: slv_array_t(1 downto 0)(95 downto 0);

    signal make_hint_m_axis_tdata: std_logic_vector(63 downto 0);
    signal make_hint_m_axis_tuser, make_hint_m_axis_tvalid, make_hint_m_axis_tready: std_logic;

    -- use_hint signals
    signal use_hint_s_axis_tdata: std_logic_vector(63 downto 0);
    signal use_hint_s_axis_tvalid, use_hint_s_axis_tready: std_logic;

    signal use_hint_m_axis_tdata: std_logic_vector(23 downto 0);
    signal use_hint_m_axis_tvalid, use_hint_m_axis_tready: std_logic;

    signal use_hint_hints_invalid: std_logic;

    signal use_hint_s_axis_shares_tdata_r: slv_array_t(1 downto 0)(63 downto 0);
    signal use_hint_s_axis_shares_tvalid_r: std_logic;

    signal sig_invalid: std_logic;

    -- verify signals
    signal verified, verified_vld: std_logic;

    -- input transactions signals
    signal in_mode: std_logic_vector(3 downto 0);
    signal in_decode_mode: std_logic_vector(3 downto 0);
    signal in_transaction_offset: natural range 0 to 31;

    signal in_rdy, in_next_mode: std_logic;

    -- output transactions signals
    signal outputing: std_logic;
    signal out_mode: std_logic_vector(2 downto 0);
    signal out_transaction_last: std_logic;
    signal out_transaction_offset_tmp, out_transaction_offset: natural range 0 to 31;
    signal out_pk: std_logic;

    signal out_data: slv_array_t(1 downto 0)(63 downto 0);
    signal out_vld: std_logic;

    signal outputed_s1_s2: std_logic;
    signal s1_s2_counter: natural range 0 to 959;

    -- signals for debugging during simulation
    signal DATA_DEBUG: std_logic_vector(2047 downto 0);

    -- assigning DON'T TOUCH attribute
    attribute dont_touch: string;
    attribute dont_touch of decode_m_axis_shares_tdata_r, unmasked_coeffs_in_r, use_hint_s_axis_shares_tdata_r: signal is "yes";

    component sec_bound_check is
    generic (
        SIMULATION: boolean := false
    );
    port (
        clk: in std_logic;
        rst: in std_logic;

        conversion_bound_check_mode: out std_logic_vector(3 downto 0);

        conversion_s_axis_tdata: out slv_array_t(1 downto 0)(95 downto 0);
        conversion_s_axis_tvalid: out std_logic;
        conversion_s_axis_tready: in std_logic;

        conversion_m_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
        conversion_m_axis_tvalid: in std_logic;

        s_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
        s_axis_tuser: in std_logic_vector(3 downto 0);
        s_axis_tvalid: in std_logic;
        s_axis_tready: out std_logic;

        invalid: out std_logic;
        invalid_vld: out std_logic
    );
    end component;

    component sec_conversion is
    port (
        clk: in std_logic;
        rst: in std_logic;

        random: in std_logic_vector(775 downto 0);

        bound_check_mode: in std_logic_vector(3 downto 0) := "1100";

        s_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
        s_axis_tuser: in std_logic_vector(3 downto 0);
        s_axis_tvalid: in std_logic;
        s_axis_tready: out std_logic;

        m_axis_tdata: out slv_array_t(1 downto 0)(95 downto 0);
        m_axis_tuser: out std_logic_vector(3 downto 0);
        m_axis_tvalid: out std_logic;
        m_axis_tready: in std_logic
    );
    end component;

    component sec_decoder is
    port (
        clk: in std_logic;
        rst: in std_logic;

        conversion_s_axis_tdata: out slv_array_t(1 downto 0)(95 downto 0);
        conversion_s_axis_tvalid: out std_logic;
        conversion_s_axis_tready: in std_logic;

        conversion_m_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
        conversion_m_axis_tvalid: in std_logic;
        conversion_m_axis_tready: out std_logic;

        s_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
        s_axis_tvalid: in std_logic;
        s_axis_tready: out std_logic;

        m_axis_tdata: out slv_array_t(1 downto 0)(7 downto 0);
        m_axis_tvalid: out std_logic;
        m_axis_tready: in std_logic
    );
    end component;

    component sec_decompose is
    port (
        clk: in std_logic;
        rst: in std_logic;

        conversion_s_axis_tdata: out slv_array_t(1 downto 0)(95 downto 0);
        conversion_s_axis_tuser: out std_logic_vector(3 downto 0);
        conversion_s_axis_tvalid: out std_logic;
        conversion_s_axis_tready: in std_logic;

        conversion_m_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
        conversion_m_axis_tuser: in std_logic_vector(3 downto 0);
        conversion_m_axis_tvalid: in std_logic;
        conversion_m_axis_tready: out std_logic;

        s_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
        s_axis_tuser: in std_logic;
        s_axis_tvalid: in std_logic;
        s_axis_tready: out std_logic;

        m_axis_tdata: out std_logic_vector(23 downto 0);
        m_axis_low_bits_tdata: out slv_array_t(1 downto 0)(95 downto 0);
        m_axis_tvalid: out std_logic;
        m_axis_tready: in std_logic
    );
    end component;

    component sec_decompressed_comparison is
    port (
        clk: in std_logic;
        rst: in std_logic;

        conversion_s_axis_tdata: out slv_array_t(1 downto 0)(95 downto 0);
        conversion_s_axis_tvalid: out std_logic;
        conversion_s_axis_tready: in std_logic;

        conversion_m_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
        conversion_m_axis_tvalid: in std_logic;

        r: in std_logic_vector(7 downto 0);

        re_encrypted: out std_logic;

        s_axis_tdata: in slv_array_t(1 downto 0)(95 downto 0);
        s_axis_tuser: in std_logic_vector(1 downto 0);
        s_axis_tvalid: in std_logic;
        s_axis_tready: out std_logic;

        invalid: out std_logic;
        invalid_vld: out std_logic
    );
    end component;

    attribute dont_touch of sec_bound_check, sec_conversion, sec_decoder, sec_decompose, sec_decompressed_comparison: component is "yes";
begin
    component_mode_next <= not mode_vld;

    s_axis_tready <= in_rdy;

    m_axis_tdata <= out_data;
    m_axis_tlast <= out_transaction_last;
    m_axis_tvalid <= out_vld;

    -- determine if we do dilithium or kyber and correct security parameters
    proc_param: process(clk) is
    begin
        if rising_edge(clk) then
            if mode_vld = '0' then
                if component_mode(8 downto 6) /= "000" then
                    is_dilithium <= '1';
                    param_k <= dilithium_k(component_mode(10 downto 9));
                    param_l <= dilithium_l(component_mode(10 downto 9));
                else
                    is_dilithium <= '0';
                    param_k <= kyber_k(component_mode(10 downto 9));
                end if;
            end if;
        end if;
    end process;

    -- Store current mode of this component

    proc_mode: process(clk) is
    begin
        if rising_edge(clk) then
            if mode_vld = '0' then
                mode <= component_mode;
            end if;

            if rst = '1' then
                mode_vld <= '0';
                running <= '0';
            else
                if component_mode_vld = '1' then
                    mode_vld <= '1';
                end if;

                running <= mode_vld;

                if (out_vld and m_axis_tready and out_transaction_last) = '1' then
                    mode_vld <= '0';
                    running <= '0';
                end if;
            end if;
        end if;
    end process;


    -- Decode initial data, that are not part of coefficients
    -- Also hold additional data, like hashing seeds, that are computed later

    proc_data: process(clk) is
        variable addr: natural range 0 to 31;
    begin
        if rising_edge(clk) then
            if in_mode(0) = '1' then
                addr := in_transaction_offset;
            elsif keccak_m_axis_tvalid = '1' then
                case keccak_mode_out is
                    -- rho, rho_prime, K for dilithium key_gen
                    when "0000" =>
                        if keccak_out_transactions_count < 4 then
                            addr := keccak_out_transactions_count;
                        else
                            addr := 12 + keccak_out_transactions_count;
                        end if;
                    -- tr for dilithium key_gen
                    when "0011" => addr := 8 + keccak_out_transactions_count;
                    -- mu for dilithium sign
                    when "0100" => addr := 8 + keccak_out_transactions_count;
                    -- rho_prime for ExpandA and ExpandMask for dilithium sign
                    when "0101" => addr := 16 + keccak_out_transactions_count;
                    -- c - part of signature
                    when "0111" => addr := 24 + keccak_out_transactions_count;
                    -- rho, sigma for kyber pke_key_gen
                    when "1001" =>
                        if keccak_out_transactions_count < 4 then
                            addr := keccak_out_transactions_count;
                        else
                            addr := 12 + keccak_out_transactions_count;
                        end if;
                    -- H(pk)
                    when "1100" => addr := 8 + keccak_out_transactions_count;
                    -- G(m || H(pk))
                    when "1101" => addr := 12 + keccak_out_transactions_count;
                    -- J(z || c)
                    when "1110" => addr := 28 + keccak_out_transactions_count;
                    when others => addr := 0;
                end case;
            elsif (sec_decoder_m_axis_tvalid and (not mode(2))) = '1' then
                addr := 16 + (sec_decoder_transactions_count / 8);
            end if;

            if in_mode(0) = '1' then
                data_0(addr) <= s_axis_tdata(0);
                data_1(addr) <= s_axis_tdata(1);
            elsif keccak_m_axis_tvalid = '1' then
                case keccak_mode_out is
                    when "0000" | "1001" =>
                        if keccak_out_transactions_count < 4 then
                            -- safe to unmask as the value is public seed for matrix A expansion
                            data_0(addr) <= keccak_m_axis_tdata(0) xor keccak_m_axis_tdata(1);
                            data_1(addr) <= (others => '0');
                        else
                            data_0(addr) <= keccak_m_axis_tdata(0);
                            data_1(addr) <= keccak_m_axis_tdata(1);
                        end if;
                    when "0011" | "0100" | "0101" | "0111" | "1100" | "1101" | "1110" =>
                        data_0(addr) <= keccak_m_axis_tdata(0);
                        data_1(addr) <= keccak_m_axis_tdata(1);
                    when others =>
                end case;
            -- during decapsulation store masked message
            elsif (sec_decoder_m_axis_tvalid and sec_decoder_m_axis_tready) = '1' then
                data_0(addr) <= sec_decoder_m_axis_tdata(0) & current_data(0)(63 downto 8);
                data_1(addr) <= sec_decoder_m_axis_tdata(1) & current_data(1)(63 downto 8);
            end if;

            if running = '0' then
                seed_vld <= '0';
                seeds_vld <= '0';
                tr_vld <= '0';
                c_vld <= '0';
                mu_vld <= '0';

                -- this is just for simulation testing, won't infer RAM with this
                if SIMULATION then
                    data_0 <= (others => (others => '0'));
                    data_1 <= (others => (others => '0'));
                end if;
            else
                if (keccak_m_axis_tvalid and keccak_out_transactions_last) = '1' then
                    case keccak_mode_out is
                        when "0000" | "0101" | "1001" | "1101" => seeds_vld <= '1';
                        when "0011" | "1100" => tr_vld <= '1';
                        when "0100" => mu_vld <= '1';
                        when "0111" => c_vld <= '1';
                        when others =>
                    end case;
                -- during decapsulation store masked message
                elsif (sec_decoder_m_axis_tvalid and sec_decoder_m_axis_tready) = '1' and sec_decoder_transactions_count = 31 then
                    mu_vld <= '1';
                elsif s_axis_tvalid = '1' then
                    -- during key_gen seed is loaded from input
                    if (mode(0) or mode(3) or mode(6)) = '1' and in_transaction_offset = 3 then
                        seed_vld <= '1';
                    end if;

                    -- during pke_enc r is loaded from input
                    if mode(1) = '1' and in_transaction_offset = 19 then
                        seeds_vld <= '1';
                    end if;

                    -- during verify rho is loaded from input
                    if mode(8) = '1' and in_transaction_offset = 3 then
                        seeds_vld <= '1';
                    end if;

                    -- during kem_dec and sign H(pk) is loaded from input
                    if (mode(5) or mode(7)) = '1' and in_transaction_offset = 15 then
                        tr_vld <= '1';
                    end if;

                    -- during verify c is loaded from input
                    if mode(8) = '1' and in_transaction_offset = 24 + natural_for_sec_level(mode(10 downto 9), 3, 5, 7) then
                        c_vld <= '1';
                    end if;
                end if;

                if sig_invalid = '1' then
                    c_vld <= '0';
                end if;
            end if;
        end if;
    end process;

    proc_data_read: process(all) is
        variable addr: natural range 0 to 31;
    begin
        addr := 0;

        if (outputing and out_mode(0)) = '1' then
            addr := out_transaction_offset;
        elsif keccak_m_axis_tvalid = '1' and keccak_mode_out = "0111" then
            addr := 24 + keccak_out_transactions_count;
        elsif (sec_decoder_m_axis_tvalid and (not mode(2))) = '1' then
            addr := 16 + (sec_decoder_transactions_count / 8);
        else
            -- see `proc_keccak_in` for explanation what hashes are computed
            case keccak_mode_in is
                when "0001" | "0110" | "1010" | "1011" => addr := 16 + keccak_transactions_count;
                when "0100" | "0111" => addr := 8 + keccak_transactions_count;
                when "0101" => if keccak_transactions_count < 4 then addr := 4 + keccak_transactions_count; elsif keccak_transactions_count < 8 then addr := 12 + keccak_transactions_count; else addr := keccak_transactions_count; end if;
                when "1000" => if keccak_transactions_count < 8 then addr := 24 + keccak_transactions_count; end if;
                when "1100" => addr := out_transaction_offset;
                when "1101" => if keccak_transactions_count < 4 then addr := 16 + keccak_transactions_count; else addr := 4 + keccak_transactions_count; end if;
                when "1110" => addr := 12 + keccak_transactions_count;
                when others => addr := keccak_transactions_count;
            end case;
        end if;

        current_data(0) <= data_0(addr);
        current_data(1) <= data_1(addr);
    end process;

    -- Increment counters for hashing during polynomial samplings

    proc_counters: process(clk) is
    begin
        if rising_edge(clk) then
            if running = '0' then
                count_i <= x"00";
                count_j <= x"00";
                count_k <= x"0000";
            else
                -- reset counter for ExpandA
                if sig_invalid = '1' then
                    count_i <= x"00";
                end if;

                if keccak_read_all = '1' then
                    case keccak_mode_out is
                        -- increment counters during ExpandMask, ExpandS and PRF
                        when "0001" | "0110" | "1010" | "1011" => count_k <= count_k + 1;
                        -- increment counters during ExpandA
                        when "0010" =>
                            if count_j = param_k - 1 then
                                count_j <= x"00";

                                count_i <= count_i + 1;
                            else
                                count_j <= count_j + 1;
                            end if;
                        when others =>
                    end case;
                end if;
            end if;
        end if;
    end process;

    -- Coefficients decoding
    -- coefficients are decoded from input, only during ExpandMask operation they are decoded from keccak output

    decode_shares_g: for i in 0 to 1 generate
        decode: entity work.decode
        port map (
            clk => clk,
            rst => not running,

            s_axis_tdata => decode_s_axis_tdata(i),
            s_axis_tuser => decode_s_axis_tuser,
            s_axis_tvalid => decode_s_axis_tvalid,
            s_axis_tready => decode_s_axis_tready(i),

            m_axis_tdata => decode_m_axis_tdata(i),
            m_axis_tuser => decode_m_axis_tuser(i),
            m_axis_tvalid => decode_m_axis_tvalid(i),
            m_axis_tready => decode_m_axis_tready
        );
    end generate;

    decode_s_axis_tdata <= keccak_m_axis_tdata when keccak_mode_out = "0110" else s_axis_tdata;
    decode_s_axis_tuser <= "1001" when keccak_mode_out = "0110" and mode(10 downto 9) = "00" else
        "1000" when keccak_mode_out = "0110" else
        in_decode_mode;
    decode_s_axis_tvalid <= keccak_m_axis_tvalid when keccak_mode_out = "0110" else
        -- make sure it is correctly synchronized, when input is also fed to keccak
        (in_mode(1) and s_axis_tvalid) and (not in_mode(2) or (keccak_s_axis_tready and not keccak_last_absorbing_iteration and keccak_source(1) and keccak_source_vld));

    -- coefficients are passed to `sec_conversion` when processing secret keys, otherwise are always passed to `compress` component
    with decode_m_axis_tuser(0) select decode_m_axis_tready <=
        sec_conversion_s_axis_tready when "0101" | "0111" | "1110" | "1111",
        (sec_conversion_s_axis_tready and mode(7)) or (((not decode_m_axis_shares_tvalid_r) or compress_s_axis_tready) and mode(8)) when "1000" | "1001",
        ((not decode_m_axis_shares_tvalid_r) or compress_s_axis_tready) when others;

    -- make sure there are never secret data before combining the shares
    decode_p: process(clk) is
    begin
        if rising_edge(clk) then
            if (((not decode_m_axis_shares_tvalid_r) or compress_s_axis_tready) and decode_m_axis_tvalid(0)) = '1' then
                case decode_m_axis_tuser(0) is
                    -- decoded secret keys are passed to `sec_conversion`
                    when "0101" | "0111" | "1110" | "1111" =>
                    when "1000" | "1001" =>
                        if mode(8) = '1' then
                            decode_m_axis_shares_tdata_r <= decode_m_axis_tdata;
                            decode_m_axis_shares_tuser_r <= decode_m_axis_tuser(0);
                        end if;
                    when others =>
                        decode_m_axis_shares_tdata_r <= decode_m_axis_tdata;
                        decode_m_axis_shares_tuser_r <= decode_m_axis_tuser(0);
                end case;
            end if;

            if rst = '1' then
                decode_m_axis_shares_tvalid_r <= '0';
            else
                if decode_m_axis_tvalid(0) = '1' then
                    case decode_m_axis_tuser(0) is
                        -- decoded secret keys are passed to `sec_conversion`
                        when "0101" | "0111" | "1110" | "1111" =>
                        when "1000" | "1001" =>
                            if mode(8) = '1' then
                                decode_m_axis_shares_tvalid_r <= '1';
                            end if;
                        when others => decode_m_axis_shares_tvalid_r <= '1';
                    end case;
                elsif compress_s_axis_tready = '1' then
                    decode_m_axis_shares_tvalid_r <= '0';
                end if;
            end if;
        end if;
    end process;

    -- Coefficients encoding

    encode_shares_g: for i in 0 to 1 generate
        encode: entity work.encode
        port map (
            clk => clk,
            rst => not running or sig_invalid,

            s_axis_tdata => encode_s_axis_tdata(i),
            s_axis_tuser => encode_s_axis_tuser,
            s_axis_tvalid => encode_s_axis_tvalid,
            s_axis_tready => encode_s_axis_tready(i),

            m_axis_tdata => encode_m_axis_tdata(i),
            m_axis_tvalid => encode_m_axis_tvalid(i),
            m_axis_tready => encode_m_axis_tready
        );
    end generate;

    proc_encode: process(all) is
    begin
        encode_s_axis_tdata <= (others => (others => '0'));

        -- w1 recovered from `use_hint`
        if use_hint_m_axis_tvalid = '1' then
            for i in 0 to 3 loop
                encode_s_axis_tdata(0)(5 + 24 * i downto 24 * i) <= use_hint_m_axis_tdata(5 + 6 * i downto 6 * i);
            end loop;

            encode_s_axis_tuser <= "1100" when mode(10 downto 9) = "00" else "1101";
            encode_s_axis_tvalid <= '1';
        -- masked message from `sec_decoder` during pke_dec
        elsif (sec_decoder_m_axis_tvalid and mode(2)) = '1' then
            for i in 0 to 7 loop
                encode_s_axis_tdata(0)(12 * i) <= sec_decoder_m_axis_tdata(0)(i);
                encode_s_axis_tdata(1)(12 * i) <= sec_decoder_m_axis_tdata(1)(i);
            end loop;

            encode_s_axis_tuser <= "0101";
            encode_s_axis_tvalid <= '1';
        -- kyber keys
        elsif (mode(0) or mode(3)) = '1' then
            encode_s_axis_tuser <= "0000";

            -- t coeffs
            if out_pk = '1' then
                encode_s_axis_tdata(0) <= unmasked_coeffs;
                encode_s_axis_tvalid <= unmasked_coeffs_vld;
            -- s coeffs
            else
                encode_s_axis_tdata <= sec_conversion_m_axis_tdata;
                encode_s_axis_tvalid <= sec_conversion_m_axis_tvalid;
            end if;
        -- dilithium s1, s2
        elsif (mode(6) and (not outputed_s1_s2) and (not out_pk)) = '1' and sec_conversion_m_axis_tuser = "1000" then
            encode_s_axis_tuser <= std_logic_vector_for_sec_level(mode(10 downto 9), "1111", "1110", "1111");

            encode_s_axis_tdata <= sec_conversion_m_axis_tdata;
            encode_s_axis_tvalid <= sec_conversion_m_axis_tvalid;
        -- w1 high bits
        elsif (sec_decompose_m_axis_tvalid and (not c_vld)) = '1' then
            for i in 0 to 3 loop
                encode_s_axis_tdata(0)(5 + 24 * i downto 24 * i) <= sec_decompose_m_axis_tdata(5 + 6 * i downto 6 * i);
            end loop;

            encode_s_axis_tuser <= "110" & (or mode(10 downto 9));
            encode_s_axis_tvalid <= '1';
        -- all compressed coefficients + t1 high bits for dilithium's key_gen
        else
            encode_s_axis_tdata(0) <= compress_m_axis_tdata;

            encode_s_axis_tuser <= compress_m_axis_tuser(3 downto 0);
            encode_s_axis_tvalid <= compress_m_axis_tvalid and (compress_mode_compress or (compress_mode_high_bits and mode(6)));
        end if;
    end process;

    encode_m_axis_tready <= m_axis_tready and keccak_s_axis_tready and not keccak_last_absorbing_iteration and not keccak_source(0) when out_mode(1) = '1' and (keccak_mode_in = "0011" or keccak_mode_in = "1100") else
        keccak_s_axis_tready and not keccak_last_absorbing_iteration and not keccak_source(0) when keccak_mode_in = "0111" or keccak_mode_in = "1101" else
        m_axis_tready when out_mode(1) = '1' else
        mode(5);

    -- Unmask

    unmasked_coeffs_next <= encode_s_axis_tready(0) and out_pk when (mode(0) or mode(3)) = '1' else compress_s_axis_tready;

    -- make sure there are never secret data before combining the shares
    unmask_p: process(clk) is
    begin
        if rising_edge(clk) then
            if ((not unmasked_coeffs_in_vld_r) or (not unmasked_coeffs_vld) or unmasked_coeffs_next) = '1' then
                if coeffs_fifo0_dout_vld = '1' and (coeffs_fifo0_mode_dout = "0000" or coeffs_fifo0_mode_dout = "0110" or coeffs_fifo0_mode_dout = "1000" or coeffs_fifo0_mode_dout = "1011" or coeffs_fifo0_mode_dout = "1101") then
                    unmasked_coeffs_in_r <= coeffs_fifo0_dout;
                end if;

                unmasked_coeffs_in_mode_r <= coeffs_fifo0_mode_dout(2);
            end if;

            if ((not unmasked_coeffs_vld) or unmasked_coeffs_next) = '1' then
                for i in 0 to 3 loop
                    unmasked_coeffs(23 + 24 * i downto 24 * i) <= add_reduce(unmasked_coeffs_in_r(0)(23 + 24 * i downto 24 * i), unmasked_coeffs_in_r(1)(23 + 24 * i downto 24 * i), is_dilithium);
                end loop;

                unmask_mode_reg <= unmasked_coeffs_in_mode_r;
            end if;

            if rst = '1' then
                unmasked_coeffs_in_vld_r <= '0';
                unmasked_coeffs_vld <= '0';
            else
                -- unmask kyber's public key or ciphertext
                if coeffs_fifo0_dout_vld = '1' and (coeffs_fifo0_mode_dout = "0000" or coeffs_fifo0_mode_dout = "0110" or coeffs_fifo0_mode_dout = "1000" or coeffs_fifo0_mode_dout = "1011" or coeffs_fifo0_mode_dout = "1101") and mode(5) = '0' then
                    unmasked_coeffs_in_vld_r <= '1';
                elsif ((not unmasked_coeffs_vld) or unmasked_coeffs_next) = '1' then
                    unmasked_coeffs_in_vld_r <= '0';
                end if;

                if unmasked_coeffs_in_vld_r = '1' then
                    unmasked_coeffs_vld <= '1';
                elsif unmasked_coeffs_next = '1' then
                    unmasked_coeffs_vld <= '0';
                end if;
            end if;
        end if;
    end process;

    -- Mask conversion

    sec_conversion_i: entity work.sec_conversion
    port map (
        clk => clk,
        rst => (not running) or sig_invalid or (sample_m_axis_tvalid and sample_m_axis_tready and sample_m_axis_tlast and (sample_m_axis_tuser(1) or sample_m_axis_tuser(0))),

        random => sec_conversion_random,
        random_mode => sec_conversion_random_mode,

        bound_check_mode => sec_conversion_bound_check_mode,

        s_axis_tdata => sec_conversion_s_axis_tdata,
        s_axis_tuser => sec_conversion_s_axis_tuser,
        s_axis_tvalid => sec_conversion_s_axis_tvalid,
        s_axis_tready => sec_conversion_s_axis_tready,

        m_axis_tdata => sec_conversion_m_axis_tdata,
        m_axis_tuser => sec_conversion_m_axis_tuser,
        m_axis_tvalid => sec_conversion_m_axis_tvalid,
        m_axis_tready => sec_conversion_m_axis_tready
    );

    sec_conversion_p: process(all) is
    begin
        -- by default not used, only when bound check is active will set it to correct value
        sec_conversion_bound_check_mode <= "1100";
        sec_conversion_s_axis_tdata <= (others => (others => '0'));
        sec_conversion_s_axis_tuser <= (others => '0');
        sec_conversion_s_axis_tvalid <= '0';

        case sec_conversion_mode_in is
            -- use for `sec_decompose`
            when "0010" | "0100" | "0111" =>
                sec_conversion_s_axis_tdata <= sec_decompose_conversion_s_axis_tdata;
                sec_conversion_s_axis_tuser <= sec_decompose_conversion_s_axis_tuser;
                sec_conversion_s_axis_tvalid <= sec_decompose_conversion_s_axis_tvalid;
            -- use for `sec_bound_check`
            when "0011" | "0101" | "0110" =>
                sec_conversion_bound_check_mode <= sec_bound_check_conversion_bound_check_mode;
                sec_conversion_s_axis_tdata <= sec_bound_check_conversion_s_axis_tdata;
                sec_conversion_s_axis_tuser <= "1000";
                sec_conversion_s_axis_tvalid <= sec_bound_check_conversion_s_axis_tvalid;
            -- use for sampleCBD
            when "1000" =>
                sec_conversion_s_axis_tdata <= sample_conversion_s_axis_tdata;
                sec_conversion_s_axis_tuser <= sample_conversion_s_axis_tuser;
                sec_conversion_s_axis_tvalid <= sample_conversion_s_axis_tvalid;
            -- use for `sec_decoder`
            when "1001" =>
                sec_conversion_bound_check_mode <= mode(10 downto 9) & "11";
                sec_conversion_s_axis_tdata <= sec_decoder_conversion_s_axis_tdata;
                sec_conversion_s_axis_tuser <= "0000";
                sec_conversion_s_axis_tvalid <= sec_decoder_conversion_s_axis_tvalid;
            when others =>
                -- b2a of decrypted message
                if (sec_decoder_m_axis_tvalid and (not mode(2))) = '1' then
                    for i in 0 to 7 loop
                        sec_conversion_s_axis_tdata(0)(11 + 12 * i downto 12 * i) <= x"681" when sec_decoder_m_axis_tdata(0)(i) = '1' else x"000";
                        sec_conversion_s_axis_tdata(1)(11 + 12 * i downto 12 * i) <= x"681" when sec_decoder_m_axis_tdata(1)(i) = '1' else x"000";
                    end loop;

                    sec_conversion_s_axis_tuser <= "0100";
                    sec_conversion_s_axis_tvalid <= '1';
                -- secret key during kyber and dilithium key_gen
                elsif coeffs_fifo0_dout_vld = '1' and coeffs_fifo0_mode_dout(2 downto 0) = "001" then
                    if is_dilithium = '1' then
                        for i in 0 to 3 loop
                            sec_conversion_s_axis_tdata(0)(23 + 24 * i downto 24 * i) <= dilithium_sub_reduce(std_logic_vector_for_sec_level(mode(10 downto 9), x"000002", x"000004", x"000002"), coeffs_fifo0_dout(0)(23 + 24 * i downto 24 * i));
                            sec_conversion_s_axis_tdata(1)(23 + 24 * i downto 24 * i) <= dilithium_sub_reduce(x"000000", coeffs_fifo0_dout(1)(23 + 24 * i downto 24 * i));
                        end loop;
                    else
                        sec_conversion_s_axis_tdata <= coeffs_fifo0_dout;
                    end if;
                    sec_conversion_s_axis_tuser <= is_dilithium & "000";
                    sec_conversion_s_axis_tvalid <= '1';
                -- b2a of decoded coefficients
                elsif decode_m_axis_tvalid(0) = '1' then
                    -- b2a of decoded message during pke_enc, kem_enc
                    if decode_m_axis_tuser(0) = "0101" then
                        for i in 0 to 7 loop
                            sec_conversion_s_axis_tdata(0)(11 + 12 * i downto 12 * i) <= x"681" when decode_m_axis_tdata(0)(12 * i) = '1' else x"000";
                            sec_conversion_s_axis_tdata(1)(11 + 12 * i downto 12 * i) <= x"681" when decode_m_axis_tdata(1)(12 * i) = '1' else x"000";
                        end loop;
                    else
                        sec_conversion_s_axis_tdata <= decode_m_axis_tdata;
                    end if;

                    sec_conversion_s_axis_tuser <= is_dilithium & "100";

                    case decode_m_axis_tuser(0) is
                        when "0101" | "0111" | "1110" | "1111" => sec_conversion_s_axis_tvalid <= decode_m_axis_tvalid(0);
                        when "1000" | "1001" => sec_conversion_s_axis_tvalid <= decode_m_axis_tvalid(0) and mode(7);
                        when others => sec_conversion_s_axis_tvalid <= '0';
                    end case;
                -- `sec_sample_bounded` during dilithium's key_gen
                elsif mode(6) = '1' then
                    sec_conversion_s_axis_tdata <= sample_conversion_s_axis_tdata;
                    sec_conversion_s_axis_tuser <= sample_conversion_s_axis_tuser;
                    sec_conversion_s_axis_tvalid <= sample_conversion_s_axis_tvalid;
                -- use for `sec_decompressed_comparison` during FO transform
                elsif mode(5) = '1' then
                    sec_conversion_s_axis_tdata <= sec_decompressed_comparison_conversion_s_axis_tdata;
                    sec_conversion_s_axis_tuser <= "0000";
                    sec_conversion_s_axis_tvalid <= sec_decompressed_comparison_conversion_s_axis_tvalid;
                end if;
        end case;

        case sec_conversion_mode_out is
            when "0010" | "0100" | "0111" => sec_conversion_m_axis_tready <= sec_decompose_conversion_m_axis_tready;
            when "0011" | "0101" | "0110" => sec_conversion_m_axis_tready <= '1';
            when "1000" => sec_conversion_m_axis_tready <= sample_conversion_m_axis_tready;
            when "1001" => sec_conversion_m_axis_tready <= sec_decoder_conversion_m_axis_tready;
            when others =>
                if (mode(0) or mode(3)) = '1' then
                    sec_conversion_m_axis_tready <= encode_s_axis_tready(0) and (not out_pk);
                elsif mode(6) = '1' and sec_conversion_m_axis_tuser = "1000" then
                    sec_conversion_m_axis_tready <= encode_s_axis_tready(0) and (not out_pk);
                elsif mode(6) = '1' then
                    sec_conversion_m_axis_tready <= sample_conversion_m_axis_tready;
                else
                    sec_conversion_m_axis_tready <= bram0_can_write;
                end if;
        end case;

        -- TODO: make this more unified
        -- correctly decodes the values of s1, s2, y for dilithium
        for i in 0 to 3 loop
            if sec_conversion_mode_out = "0001" then
                sec_conversion_m_axis_tdata_modified(0)(23 + 24 * i downto 24 * i) <= dilithium_sub_reduce(std_logic_vector_for_sec_level(mode(10 downto 9), x"020000", x"080000", x"080000"), sec_conversion_m_axis_tdata(0)(23 + 24 * i downto 24 * i));
            else
                sec_conversion_m_axis_tdata_modified(0)(23 + 24 * i downto 24 * i) <= dilithium_sub_reduce(std_logic_vector_for_sec_level(mode(10 downto 9), x"000002", x"000004", x"000002"), sec_conversion_m_axis_tdata(0)(23 + 24 * i downto 24 * i));
            end if;

            sec_conversion_m_axis_tdata_modified(1)(23 + 24 * i downto 24 * i) <= dilithium_sub_reduce(x"000000", sec_conversion_m_axis_tdata(1)(23 + 24 * i downto 24 * i));
        end loop;
    end process;

    sec_conversion_has_pending_transactions <= '1' when sec_conversion_pending_transactions /= 0 else '0';

    sec_conversion_pending_transactions_p: process(clk) is
    begin
        if rising_edge(clk) then
            if ((not running) or sig_invalid) = '1' then
                sec_conversion_pending_transactions <= 0;
            else
                if (sec_conversion_s_axis_tvalid and sec_conversion_s_axis_tready and ((not sec_conversion_m_axis_tvalid) or (not sec_conversion_m_axis_tready))) = '1' then
                    sec_conversion_pending_transactions <= sec_conversion_pending_transactions + 1;
                elsif (sec_conversion_m_axis_tvalid and sec_conversion_m_axis_tready and ((not sec_conversion_s_axis_tvalid) or (not sec_conversion_s_axis_tready))) = '1' then
                    sec_conversion_pending_transactions <= sec_conversion_pending_transactions - 1;
                end if;
            end if;
        end if;
    end process;

    sec_conversion_state_machine_in: entity work.sec_conversion_state_machine
    port map (
        clk => clk,
        rst => not running,

        mode => mode,

        sig_invalid => sig_invalid,

        next_mode => sec_conversion_s_axis_tvalid and sec_conversion_s_axis_tready,

        sec_conversion_mode => sec_conversion_mode_in
    );

    sec_conversion_state_machine_out: entity work.sec_conversion_state_machine
    port map (
        clk => clk,
        rst => not running,

        mode => mode,

        sig_invalid => sig_invalid,

        next_mode => sec_conversion_m_axis_tvalid and sec_conversion_m_axis_tready,

        sec_conversion_mode => sec_conversion_mode_out
    );

    -- Masked decoder

    sec_decoder_i: entity work.sec_decoder
    port map (
        clk => clk,
        rst => not running,

        conversion_s_axis_tdata => sec_decoder_conversion_s_axis_tdata,
        conversion_s_axis_tvalid => sec_decoder_conversion_s_axis_tvalid,
        conversion_s_axis_tready => sec_decoder_conversion_s_axis_tready,

        conversion_m_axis_tdata => sec_decoder_conversion_m_axis_tdata,
        conversion_m_axis_tvalid => sec_decoder_conversion_m_axis_tvalid,
        conversion_m_axis_tready => sec_decoder_conversion_m_axis_tready,

        s_axis_tdata => sec_decoder_s_axis_tdata,
        s_axis_tvalid => sec_decoder_s_axis_tvalid,
        s_axis_tready => sec_decoder_s_axis_tready,

        m_axis_tdata => sec_decoder_m_axis_tdata,
        m_axis_tvalid => sec_decoder_m_axis_tvalid,
        m_axis_tready => sec_decoder_m_axis_tready
    );

    sec_decoder_conversion_s_axis_tready <= sec_conversion_s_axis_tready when sec_conversion_mode_in = "1001" else '0';

    sec_decoder_conversion_m_axis_tdata <= sec_conversion_m_axis_tdata;
    sec_decoder_conversion_m_axis_tvalid <= sec_conversion_m_axis_tvalid when sec_conversion_mode_out = "1001" else '0';

    sec_decoder_s_axis_tdata <= coeffs_fifo0_dout;
    sec_decoder_s_axis_tvalid <= coeffs_fifo0_dout_vld when coeffs_fifo0_mode_dout = "1010" else '0';

    sec_decoder_m_axis_tready <= encode_s_axis_tready(0) when mode(2) = '1' else sec_conversion_s_axis_tready when sec_conversion_mode_in /= "1001" else '0';

    proc_sec_decoder_coeffs: process(clk) is
    begin
        if rising_edge(clk) then
            if running = '0' then
                sec_decoder_transactions_count <= 0;
            else
                if (sec_decoder_m_axis_tvalid and sec_decoder_m_axis_tready) = '1' then
                    if sec_decoder_transactions_count = 31 then
                        sec_decoder_transactions_count <= 0;
                    else
                        sec_decoder_transactions_count <= sec_decoder_transactions_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Masked decompose
    sec_decompose_i: entity work.sec_decompose
    port map (
        clk => clk,
        rst => (not running) or sig_invalid,

        random_q => other_random(5 downto 0),

        conversion_s_axis_tdata => sec_decompose_conversion_s_axis_tdata,
        conversion_s_axis_tuser => sec_decompose_conversion_s_axis_tuser,
        conversion_s_axis_tvalid => sec_decompose_conversion_s_axis_tvalid,
        conversion_s_axis_tready => sec_decompose_conversion_s_axis_tready,

        conversion_m_axis_tdata => sec_decompose_conversion_m_axis_tdata,
        conversion_m_axis_tvalid => sec_decompose_conversion_m_axis_tvalid,
        conversion_m_axis_tready => sec_decompose_conversion_m_axis_tready,

        s_axis_tdata => sec_decompose_s_axis_tdata,
        s_axis_tuser => sec_decompose_s_axis_tuser,
        s_axis_tvalid => sec_decompose_s_axis_tvalid,
        s_axis_tready => sec_decompose_s_axis_tready,

        m_axis_tdata => sec_decompose_m_axis_tdata,
        m_axis_low_bits_tdata => sec_decompose_m_axis_low_bits_tdata,
        m_axis_tvalid => sec_decompose_m_axis_tvalid,
        m_axis_tready => sec_decompose_m_axis_tready
    );

    with sec_conversion_mode_in select sec_decompose_conversion_s_axis_tready <=
        sec_conversion_s_axis_tready when "0010" | "0100" | "0111",
        '0' when others;

    sec_decompose_conversion_m_axis_tdata <= sec_conversion_m_axis_tdata;
    with sec_conversion_mode_out select sec_decompose_conversion_m_axis_tvalid <=
        sec_conversion_m_axis_tvalid when "0010" | "0100" | "0111",
        '0' when others;

    -- encode w1 high bits or use for `sec_bound_check` r0 low bits
    sec_decompose_m_axis_tready <= coeffs_fifo0_dout_vld when poly_mul_finished = '1' else '1' when poly_mul_next_bound_check_mode = "11" and poly_mul_running = '0' else '0' when c_vld = '1' else encode_s_axis_tready(0);

    sec_decompose_p: process(all) is
    begin
        -- compute high bits of w
        if coeffs_fifo0_dout_vld = '1' and (coeffs_fifo0_mode_dout = "0011" or coeffs_fifo0_mode_dout = "0111") then
            sec_decompose_s_axis_tdata <= coeffs_fifo0_dout;
            sec_decompose_s_axis_tuser <= or mode(10 downto 9);
            sec_decompose_s_axis_tvalid <= mode(7);
        -- compute r0 low bits
        else
            sec_decompose_s_axis_tdata <= coeffs_fifo1_dout;
            sec_decompose_s_axis_tuser <= or mode(10 downto 9);
            if coeffs_fifo1_mode_dout = "10" then
                sec_decompose_s_axis_tvalid <= coeffs_fifo1_dout_vld;
            else
                sec_decompose_s_axis_tvalid <= '0';
            end if;
        end if;
    end process;


    -- Coefficients compression/decompression

    compress: entity work.compress
    port map (
        clk => clk,
        rst => not running,

        s_axis_tdata => compress_s_axis_tdata,
        s_axis_tuser => compress_s_axis_tuser,
        s_axis_tvalid => compress_s_axis_tvalid,
        s_axis_tready => compress_s_axis_tready,

        m_axis_tdata => compress_m_axis_tdata,
        m_axis_low_bits_tdata => compress_m_axis_low_bits_tdata,
        m_axis_tuser => compress_m_axis_tuser,
        m_axis_tvalid => compress_m_axis_tvalid,
        m_axis_tready => compress_m_axis_tready
    );

    proc_compress_in: process(all) is
    begin
        compress_s_axis_tdata <= (others => '0');
        compress_s_axis_tuser <= (others => '0');
        compress_s_axis_tvalid <= '0';

        -- if there are coefficients for decompression process them
        if decode_m_axis_shares_tvalid_r = '1' then
            compress_s_axis_tuser <= "01" & decode_m_axis_shares_tuser_r;
            compress_s_axis_tdata <= decode_m_axis_shares_tdata_r(0) xor decode_m_axis_shares_tdata_r(1);

            case decode_m_axis_shares_tuser_r is
                -- decoded secret keys are passed to `sec_conversion`
                when "0101" | "0111" | "1110" | "1111" =>
                when "1000" | "1001" => compress_s_axis_tvalid <= mode(8);
                when others => compress_s_axis_tvalid <= '1';
            end case;
        -- compress u and v when outputing
        elsif (unmasked_coeffs_vld and (mode(1) or mode(4))) = '1' then
            compress_s_axis_tdata <= unmasked_coeffs;
            if unmask_mode_reg = '0' then
                compress_s_axis_tuser <= std_logic_vector_for_sec_level(mode(10 downto 9), "000010", "000010", "000001");
            else
                compress_s_axis_tuser <= std_logic_vector_for_sec_level(mode(10 downto 9), "000100", "000100", "000011");
            end if;
            compress_s_axis_tvalid <= '1';
        -- power2round of t
        elsif (unmasked_coeffs_vld and mode(6)) = '1' then
            compress_s_axis_tdata <= unmasked_coeffs;
            compress_s_axis_tuser <= "101011";
            compress_s_axis_tvalid <= '1';
        -- compress z when outputing
        elsif (unmasked_coeffs_vld and mode(7)) = '1' then
            compress_s_axis_tdata <= unmasked_coeffs;
            compress_s_axis_tuser <= std_logic_vector_for_sec_level(mode(10 downto 9), "001001", "001000", "001000");
            compress_s_axis_tvalid <= '1';
        elsif coeffs_fifo0_dout_vld = '1' then
            compress_s_axis_tdata <= coeffs_fifo0_dout(0);

            case coeffs_fifo0_mode_dout is
                -- compress t0 when outputing
                when "0010" =>
                    compress_s_axis_tuser <= "001010";
                    compress_s_axis_tvalid <= '1';
                -- compute high bits of w (during verify)
                when "0011" | "0111" =>
                    compress_s_axis_tuser <= std_logic_vector_for_sec_level(mode(10 downto 9), "101100", "101101", "101101");
                    compress_s_axis_tvalid <= mode(8);
                when others =>
            end case;
        end if;
    end process;

    compress_m_axis_tready <= not poly_mul_finished or coeffs_fifo0_dout_vld when compress_mode_low_bits = '1' else
        use_hint_s_axis_tready when compress_mode_high_bits = '1' and mode(8) = '1' else
        -- kyber's t coefficients are stored after s during pke_dec and kem_dec, otherwise immediately
        bram1_store_kyber_t when compress_m_axis_tuser = "010000" else
        bram0_can_write and (not bram0_storing_s1s2) when compress_mode_decompress = '1' else
        -- dilithium's t0
        encode_s_axis_tready(0) and outputed_s1_s2 when compress_m_axis_tuser = "001010" else
        encode_s_axis_tready(0);

    compress_mode_compress <= '1' when compress_m_axis_tuser(5 downto 4) = "00" else '0';
    compress_mode_decompress <= '1' when compress_m_axis_tuser(5 downto 4) = "01" else '0';
    compress_mode_high_bits <= '1' when compress_m_axis_tuser(5 downto 4) = "10" else '0';
    compress_mode_low_bits <= '1' when compress_m_axis_tuser(5 downto 4) = "11" else '0';

    -- Keccak

    keccak: entity work.keccak
    port map (
        clk => clk,
        rst => not running or sig_invalid,

        read_all => keccak_read_all,

        s_axis_tdata => keccak_s_axis_tdata,
        s_axis_tuser => keccak_s_axis_tuser,
        s_axis_tlast => keccak_s_axis_tlast,
        s_axis_tvalid => keccak_s_axis_tvalid,
        s_axis_tready => keccak_s_axis_tready,

        m_axis_tdata => keccak_m_axis_tdata,
        m_axis_tvalid => keccak_m_axis_tvalid,
        m_axis_tready => keccak_m_axis_tready
    );

    keccak_ready_p: process(all) is
    begin
        case keccak_mode_out is
            when "0001" | "0010" | "1010" | "1011" =>
                keccak_read_all <= sample_m_axis_tlast;
                keccak_m_axis_tready <= sample_s_axis_tready;
            when "0110" =>
                keccak_read_all <= decode_s_axis_tvalid and decode_s_axis_tready(0) and keccak_out_transactions_last;
                keccak_m_axis_tready <= decode_s_axis_tready(0);
            when "1000" =>
                keccak_read_all <= sample_in_ball_m_axis_tvalid;
                keccak_m_axis_tready <= sample_in_ball_transactions_last;
            when others =>
                keccak_read_all <= keccak_m_axis_tvalid and keccak_out_transactions_last;
                keccak_m_axis_tready <= not in_mode(0);
        end case;
    end process;

    keccak_state_machine: entity work.keccak_state_machine
    port map (
        clk => clk,
        rst => not running,

        mode => mode,

        param_k => param_k,
        param_l => param_l,

        sig_invalid => sig_invalid,

        next_mode => keccak_s_axis_tvalid and keccak_s_axis_tready and keccak_s_axis_tlast,

        keccak_mode => keccak_mode_in
    );

    proc_keccak_in: process(all) is
    begin
        keccak_s_axis_tdata <= (others => (others => '0'));
        -- only message during mu = H(tr || msg) is indicated by `s_axis_tlast`, other use `keccak_last_absorbing_iteration`
        keccak_s_axis_tlast <= s_axis_tlast when keccak_mode_in = "0100" else keccak_last_absorbing_iteration;
        keccak_s_axis_tvalid <= '0';

        if keccak_last_absorbing_iteration = '1' then
            keccak_s_axis_tvalid <= '1';

            case keccak_mode_in is
                -- (rho, rho_prime, K) = H(seed)
                when "0000" => keccak_s_axis_tdata(0)(23 downto 0) <= x"1f" & std_logic_vector(to_unsigned(param_l, 8)) & std_logic_vector(to_unsigned(param_k, 8));
                -- H(rho' || n) - ExpandS, ExpandMask, PRF
                when "0001" | "0110" | "1010" | "1011" =>
                    if is_dilithium = '1' then
                        keccak_s_axis_tdata(0)(23 downto 0) <= x"1f" & std_logic_vector(count_k);
                    else
                        keccak_s_axis_tdata(0)(15 downto 0) <= x"1f" & std_logic_vector(count_k(7 downto 0));
                    end if;
                -- H_128(rho || n) - ExpandA, XOF
                when "0010" => keccak_s_axis_tdata(0)(23 downto 0) <= x"1f" & std_logic_vector(count_j) & std_logic_vector(count_i);
                -- H(c1) - SampleInBall
                when "1000" => keccak_s_axis_tdata(0)(7 downto 0) <= x"1f";
                -- (rho, sigma) = G(seed)
                when "1001" => keccak_s_axis_tdata(0)(15 downto 0) <= x"06" & std_logic_vector(to_unsigned(param_k, 8));
                when others => keccak_s_axis_tdata(0)(7 downto 0) <= x"06" when keccak_mode_in = "1100" or keccak_mode_in = "1101" else x"1f";
            end case;
        else
            case keccak_source is
                when "001" =>
                    keccak_s_axis_tdata <= current_data;

                    case keccak_mode_in is
                        -- (rho, rho_prime, K) = H(seed)
                        when "0000" => keccak_s_axis_tvalid <= keccak_source_vld and seed_vld;
                        -- H(rho' || n) - ExpandS, ExpandMask, PRF
                        when "0001" | "0110" | "1010" | "1011" =>
                            keccak_s_axis_tvalid <= keccak_source_vld and seeds_vld;
                        -- H_128(rho || n) - ExpandA, XOF
                        when "0010" => keccak_s_axis_tvalid <= keccak_source_vld and seeds_vld;
                        -- tr = H(pk)
                        when "0011" => keccak_s_axis_tvalid <= keccak_source_vld and seeds_vld;
                        -- mu = H(tr || msg)
                        when "0100" => keccak_s_axis_tvalid <= keccak_source_vld and tr_vld;
                        -- rho_prime = H(K || rnd || mu)
                        when "0101" => keccak_s_axis_tvalid <= keccak_source_vld and mu_vld;
                        -- c = H(mu || w1)
                        when "0111" => keccak_s_axis_tvalid <= keccak_source_vld and mu_vld;
                        -- H(c1) - SampleInBall
                        when "1000" => keccak_s_axis_tvalid <= keccak_source_vld and c_vld;
                        -- (rho, sigma) = G(seed)
                        when "1001" => keccak_s_axis_tvalid <= keccak_source_vld and seed_vld;
                        -- G(m || H(pk))
                        when "1101" => keccak_s_axis_tvalid <= keccak_source_vld and (mu_vld or (tr_vld and mode(4)));
                        -- J(z || c)
                        when "1110" => keccak_s_axis_tvalid <= keccak_source_vld and tr_vld;
                        when others =>
                    end case;
                when "010" =>
                    keccak_s_axis_tdata <= s_axis_tdata;
                    keccak_s_axis_tvalid <= keccak_source_vld and s_axis_tvalid and (in_mode(2) or not is_dilithium) and (not in_mode(1) or decode_s_axis_tready(0));
                when "100" =>
                    if keccak_mode_in = "1100" and out_mode(0) = '1' then
                        keccak_s_axis_tdata(0) <= current_data(0);
                        keccak_s_axis_tvalid <= outputing and m_axis_tready;
                    else
                        keccak_s_axis_tdata <= encode_m_axis_tdata;
                        keccak_s_axis_tvalid <= keccak_source_vld and encode_m_axis_tvalid(0) and (not out_mode(1) or m_axis_tready);
                    end if;
                when others =>
            end case;
        end if;
    end process;

    with keccak_mode_in select keccak_s_axis_tuser <=
        "00" when "0010",
        "11" when "1001" | "1101",
        "10" when "1100",
        "01" when others;

    -- SHAKE-128 uses r = 1344 => 21 64b transactions
    -- SHAKE-256 uses r = 1088 => 17 64b transactions
    -- SHA3-256 uses r = 1088 => 17 64b transactions
    -- SHA3-512 uses r = 576 => 9 64b transactions
    with keccak_mode_in select keccak_transactions_count_last <=
        20 when "0010",
        8 when "1001" | "1101",
        16 when others;

    keccak_transactions_last <= '1' when keccak_transactions_count = keccak_transactions_count_last else keccak_s_axis_tlast;

    proc_keccak_source: process(clk) is
    begin
        if rising_edge(clk) then
            if keccak_first_transaction = '1' then
                case keccak_mode_in is
                    when "1100" => keccak_source <= "010" when mode(4) = '1' else "100";
                    when "1101" => keccak_source <= "001" when mode(5) = '1' else "010";
                    when "1111" => keccak_source <= "000";
                    when others => keccak_source <= "001";
                end case;
            elsif (keccak_s_axis_tvalid and keccak_s_axis_tready) = '1' then
                if keccak_transactions_count = 7 then
                    case keccak_mode_in is
                        when "0100" => keccak_source <= "010";
                        when "0111" => keccak_source <= "100";
                        when others =>
                    end case;
                end if;

                if keccak_transactions_count = 3 then
                    case keccak_mode_in is
                        when "0011" => keccak_source <= "010" when mode(8) = '1' else "100";
                        when "1101" => keccak_source <= "001";
                        when "1110" => keccak_source <= "010";
                        when others =>
                    end case;
                end if;
            end if;

            if (not running or sig_invalid) = '1' then
                keccak_source_vld <= '0';
            else
                if (keccak_s_axis_tvalid and keccak_s_axis_tready and keccak_s_axis_tlast) = '1' then
                    keccak_source_vld <= '0';
                else
                    keccak_source_vld <= '1';
                end if;
            end if;
        end if;
    end process;

    proc_keccak: process(clk) is
    begin
        if rising_edge(clk) then
            if (not running or sig_invalid) = '1' then
                keccak_mode_out <= (others => '0');

                keccak_first_transaction <= '1';
                keccak_last_absorbing_iteration <= '0';

                keccak_transactions_count <= 0;
            else
                if (keccak_s_axis_tvalid and keccak_s_axis_tready) = '1' then
                    keccak_first_transaction <= keccak_s_axis_tlast;

                    if keccak_transactions_last = '1' then
                        keccak_last_absorbing_iteration <= '0';

                        keccak_transactions_count <= 0;
                    else
                        keccak_transactions_count <= keccak_transactions_count + 1;
                    end if;
                end if;

                if (keccak_s_axis_tlast and keccak_s_axis_tvalid) = '1' then
                    keccak_mode_out <= keccak_mode_in;
                end if;

                -- for mu = H(tr || msg) padding is already added to message
                if keccak_last_absorbing_iteration = '0' and keccak_mode_in /= "0100" then
                    keccak_last_absorbing_iteration <= keccak_in_transactions_last and keccak_s_axis_tvalid and keccak_s_axis_tready;
                end if;
            end if;
        end if;
    end process;

    with keccak_mode_in select keccak_in_transactions_count_last <=
        3 when "0000" | "0010" | "1001",
        natural_for_mode(is_dilithium, 3, 7) when "0001" | "0110" | "1010" | "1011",
        dilithium_pk_transactions(mode(10 downto 9)) - 1 when "0011",
        15 when "0101",
        -- + 8 for mu
        dilithium_w1_transactions(mode(10 downto 9)) - 1 + 8 when "0111",
        dilithium_c_transactions(mode(10 downto 9)) - 1 when "1000",
        kyber_pk_transactions(mode(10 downto 9)) - 1 when "1100",
        7 when "1101",
        -- + 4 for z
        kyber_c_transactions(mode(10 downto 9)) - 1 + 4 when "1110",
        0 when others;

    keccak_out_transactions_count_last_y <= 71 when mode(10 downto 9) = "00" else 79;

    -- SHAKE-128 uses r = 1344 => 21 64b transactions
    -- SHAKE-256 uses r = 1088 => 17 64b transactions
    with keccak_mode_out select keccak_out_transactions_count_last <=
        -- rho (4), rho_prime (8), K (4)
        15 when "0000",
        -- tr | mu | rho_prime | rho, sigma | G(m || H(pk))
        7 when "0011" | "0100" | "0101" | "1001" | "1101",
        -- c
        dilithium_c_transactions(mode(10 downto 9)) - 1 when "0111",
        -- H(pk) | K_
        3 when "1100" | "1110",
        20 when "0010",
        -- ExpandMask
        keccak_out_transactions_count_last_y when "0110",
        16 when others;

    keccak_in_transactions_last <= '1' when keccak_in_transactions_count = keccak_in_transactions_count_last else '0';
    keccak_out_transactions_last <= '1' when keccak_out_transactions_count = keccak_out_transactions_count_last else '0';

    proc_keccak_transactions: process(clk) is
    begin
        if rising_edge(clk) then
            if (not running or sig_invalid) = '1' then
                keccak_in_transactions_count <= 0;
                keccak_out_transactions_count <= 0;
            else
                if (keccak_s_axis_tvalid and keccak_s_axis_tready) = '1' then
                    if (keccak_in_transactions_last or keccak_s_axis_tlast) = '1' then
                        keccak_in_transactions_count <= 0;
                    else
                        keccak_in_transactions_count <= keccak_in_transactions_count + 1;
                    end if;
                end if;

                if keccak_read_all = '1' then
                    keccak_out_transactions_count <= 0;
                else
                    if (keccak_m_axis_tvalid and keccak_m_axis_tready) = '1' then
                        if keccak_out_transactions_last = '1' then
                            keccak_out_transactions_count <= 0;
                        else
                            keccak_out_transactions_count <= keccak_out_transactions_count + 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Coefficients sampling

    sample: entity work.sample
    port map (
        clk => clk,
        rst => not running,

        random => other_random,

        mode => sec_sample_bounded_mode,

        sec_conversion_s_axis_tdata => sample_conversion_s_axis_tdata,
        sec_conversion_s_axis_tuser => sample_conversion_s_axis_tuser,
        sec_conversion_s_axis_tvalid => sample_conversion_s_axis_tvalid,
        sec_conversion_s_axis_tready => sample_conversion_s_axis_tready,

        sec_conversion_m_axis_tdata => sample_conversion_m_axis_tdata,
        sec_conversion_m_axis_tuser => sample_conversion_m_axis_tuser,
        sec_conversion_m_axis_tvalid => sample_conversion_m_axis_tvalid,
        sec_conversion_m_axis_tready => sample_conversion_m_axis_tready,

        s_axis_tdata => sample_s_axis_tdata,
        s_axis_tuser => sample_s_axis_tuser,
        s_axis_tvalid => sample_s_axis_tvalid,
        s_axis_tready => sample_s_axis_tready,

        m_axis_tdata => sample_m_axis_tdata,
        m_axis_tuser => sample_m_axis_tuser,
        m_axis_tlast => sample_m_axis_tlast,
        m_axis_tvalid => sample_m_axis_tvalid,
        m_axis_tready => sample_m_axis_tready
    );

    sec_sample_bounded_mode <= '1' when mode(10 downto 9) = "01" else '0';

    sample_conversion_s_axis_tready <= sec_conversion_s_axis_tready;

    sample_conversion_m_axis_tdata <= sec_conversion_m_axis_tdata;
    sample_conversion_m_axis_tuser <= sec_conversion_m_axis_tuser;
    sample_conversion_m_axis_tvalid <= sec_conversion_m_axis_tvalid when sec_conversion_mode_out = "1000" else sec_conversion_m_axis_tvalid and mode(6) when sec_conversion_m_axis_tuser /= "1000" else '0';

    sample_s_axis_tdata <= keccak_m_axis_tdata;

    proc_sample_in: process(all) is
    begin
        case keccak_mode_out is
            -- ExpandMask
            when "0001" =>
                sample_s_axis_tuser <= std_logic_vector_for_sec_level(mode(10 downto 9), "101", "110", "101");
                sample_s_axis_tvalid <= keccak_m_axis_tvalid;
            -- ExpandA, SampleNTT
            when "0010" =>
                sample_s_axis_tuser <= is_dilithium & "00";
                sample_s_axis_tvalid <= keccak_m_axis_tvalid;
            -- SamplePolyCBD
            when "1010" =>
                sample_s_axis_tuser <= std_logic_vector_for_sec_level(mode(10 downto 9), "010", "001", "001");
                sample_s_axis_tvalid <= keccak_m_axis_tvalid;
            -- SamplePolyCBD (ETA always == 2)
            when "1011" =>
                sample_s_axis_tuser <= "001";
                sample_s_axis_tvalid <= keccak_m_axis_tvalid;
            when others =>
                sample_s_axis_tuser <= "000";
                sample_s_axis_tvalid <= '0';
        end case;
    end process;

    sample_m_axis_tready <= (not (bram0_storing_y and sec_conversion_has_pending_transactions)) and bram0_can_write;

    -- Sample in ball

    sample_in_ball: entity work.sample_in_ball
    port map (
        clk => clk,
        rst => not running,

        mode => mode(10 downto 9),

        data_in => sample_in_ball_data_in,
        data_in_vld => sample_in_ball_data_in_vld,

        m_axis_tdata => sample_in_ball_m_axis_tdata,
        m_axis_tvalid => sample_in_ball_m_axis_tvalid,
        m_axis_tready => sample_in_ball_m_axis_tready
    );

    sample_in_ball_m_axis_tready <= bram0_can_write;

    sample_in_ball_transactions_last <= '1' when sample_in_ball_transactions_count = 7 else '0';

    proc_sample_in_ball: process(clk) is
    begin
        if rising_edge(clk) then
            sample_in_ball_data_in <= keccak_m_axis_tdata(0)(7 + 8 * sample_in_ball_transactions_count downto 8 * sample_in_ball_transactions_count);
            sample_in_ball_data_in_vld <= keccak_m_axis_tvalid when keccak_mode_out = "1000" else '0';

            if (not running or sig_invalid) = '1' then
                sample_in_ball_transactions_count <= 0;
            else
                if keccak_m_axis_tvalid = '1' and keccak_mode_out = "1000" then
                    if sample_in_ball_transactions_last = '1' then
                        sample_in_ball_transactions_count <= 0;
                    else
                        sample_in_ball_transactions_count <= sample_in_ball_transactions_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- Polynomial multiplication

    poly_mul0: entity work.poly_mul
    generic map (
        BRAM_DELAY => BRAM_DELAY
    )
    port map (
        clk => clk,
        rst => not running or sig_invalid,

        start => poly_mul_start,
        rdy => poly_mul_rdy,
        vld => poly_mul_vld,

        mode => poly_mul_mode,

        first_iteration => poly_mul_first_iteration,
        last_iteration => poly_mul_last_iteration,

        inplace_coeffs => poly_mul_inplace_coeffs(0),
        inplace_op => poly_mul_inplace_op,
        inplace_next => poly_mul_inplace_next,

        coeffs_wea => poly_mul_coeffs_wea,

        coeffs_dina => poly_mul_coeffs_dina(0),
        coeffs_doutb => poly_mul_coeffs_doutb(0),

        coeffs_addra => poly_mul_coeffs_addra,
        coeffs_addrb => poly_mul_coeffs_addrb
    );

    -- control signals are same as for `poly_mul0` so they are not used
    poly_mul1: entity work.poly_mul
    generic map (
        BRAM_DELAY => BRAM_DELAY
    )
    port map (
        clk => clk,
        rst => not running or sig_invalid,

        start => poly_mul_start,
        rdy => open,
        vld => open,

        mode => poly_mul_mode,

        first_iteration => open,
        last_iteration => open,

        inplace_coeffs => poly_mul_inplace_coeffs(1),
        inplace_op => poly_mul_inplace_op,
        inplace_next => open,

        coeffs_wea => open,

        coeffs_dina => poly_mul_coeffs_dina(1),
        coeffs_doutb => poly_mul_coeffs_doutb(1),

        coeffs_addra => open,
        coeffs_addrb => open
    );

    poly_mul_inplace_coeffs <= coeffs_fifo0_dout;
    poly_mul_inplace_op <= poly_mul_coeffs_fifo0_mode_out(1 downto 0) when poly_mul_offset_we /= "11" else "00";

    poly_mul_coeffs_doutb(0) <= bram0_doutb(0) when poly_mul_coeffs_read_bram_mux_shift_reg(0) = '0' else bram1_doutb(0);
    poly_mul_coeffs_doutb(1) <= (others => '0') when poly_mul_share_shift_reg = (poly_mul_share_shift_reg'range => '0') else poly_mul_coeffs_doutb(0) when poly_mul_share_shift_reg(0) = '0' else bram0_doutb(1) when poly_mul_coeffs_read_bram_mux_shift_reg(0) = '0' else bram1_doutb(1);

    poly_mul_state_machine: entity work.poly_mul_state_machine
    port map (
        clk => clk,
        rst => not running,

        mode => mode,

        param_k => param_k,
        param_l => param_l,

        poly_mul_start => poly_mul_start,
        poly_mul_rdy => poly_mul_rdy,
        poly_mul_vld => poly_mul_vld,

        sig_invalid => sig_invalid,

        poly_mul_next_bound_check_mode => poly_mul_next_bound_check_mode,
        poly_mul_bound_check_mode => poly_mul_bound_check_mode,

        poly_mul_mode => poly_mul_mode,
        poly_mul_coeffs_fifo_mode_in => poly_mul_coeffs_fifo0_mode_in,
        poly_mul_coeffs_fifo_mode_out => poly_mul_coeffs_fifo0_mode_out,

        poly_mul_bram_mux => poly_mul_bram_mux,
        poly_mul_first_bram_only => poly_mul_first_bram_only,
        poly_mul_repeat_read => poly_mul_repeat_read,

        poly_mul_has_shares => poly_mul_has_shares,

        poly_mul_offset_we => poly_mul_offset_we,
        poly_mul_addra_offset0 => poly_mul_addra_offset0,
        poly_mul_addra_offset1 => poly_mul_addra_offset1,
        poly_mul_addrb_offset0 => poly_mul_addrb_offset0,
        poly_mul_addrb_offset1 => poly_mul_addrb_offset1,

        poly_mul_running => poly_mul_running,
        poly_mul_half => poly_mul_half,
        poly_mul_half_finished => poly_mul_half_finished,
        poly_mul_finished => poly_mul_finished
    );

    poly_mul_coeffs_addra_last <= (and poly_mul_coeffs_addra(5 downto 0)) when is_dilithium = '1' else (and poly_mul_coeffs_addra(4 downto 0));
    poly_mul_coeffs_addra_mux <= poly_mul_coeffs_addra(6) when is_dilithium = '1' else poly_mul_coeffs_addra(5);
    poly_mul_coeffs_addrb_mux <= poly_mul_coeffs_addrb(6) when is_dilithium = '1' else poly_mul_coeffs_addrb(5);

    -- choose, which BRAM is used for reading
    -- for first iteration of NTT, we read from `bram0`, for remaining from `bram1`
    -- during multiplication (a * b) we switch between `bram0` (a) and `bram1` (b)
    -- when computing NTT of challenge during dilithium sign and verify, it will be stored back to `bram0`, so we use only it
    poly_mul_read_bram_mux <= poly_mul_bram_mux_reg when (poly_mul_first_iteration or poly_mul_coeffs_addrb_mux or poly_mul_first_bram_only) = '1' else '1';

    proc_poly_mul: process(clk) is
    begin
        if rising_edge(clk) then
            if poly_mul_start = '1' then
                poly_mul_bram_mux_reg <= poly_mul_bram_mux;
                poly_mul_has_shares_reg <= poly_mul_has_shares;
            end if;

            poly_mul_coeffs_read_bram_mux_shift_reg <= poly_mul_read_bram_mux & poly_mul_coeffs_read_bram_mux_shift_reg(poly_mul_coeffs_read_bram_mux_shift_reg'left downto 1);
            poly_mul_share_shift_reg <= ((poly_mul_has_shares_reg(0) and not poly_mul_coeffs_addrb_mux) or (poly_mul_has_shares_reg(1) and poly_mul_coeffs_addrb_mux)) & poly_mul_share_shift_reg(poly_mul_share_shift_reg'left downto 1);

            if running = '0' then
                poly_mul_start <= '0';
            else
                -- during kem_dec when message is decrypted we need to wait until it is stored
                if (mode(5) and poly_mul_half and not bram1_stored_kyber_m) = '0' and (poly_mul_next_bound_check_mode /= "11" or sec_conversion_mode_in = "0110") then
                    -- make sure `poly_mul_start` is valid only one cycle
                    -- we start computation when we have valid data in bram0 or if we compute on bram1 data
                    poly_mul_start <= not poly_mul_start and ((or bram0_polys_vld) or poly_mul_bram_mux) and poly_mul_rdy and (not (and poly_mul_mode));
                end if;
            end if;
        end if;
    end process;

    -- Coefficients memories

    -- this is used as temporary memory, it stores polynomials from decoding and sampling
    -- it is then used by `poly_mul` either for NTT or multiplication
    -- for NTT it will only read coefficients during first iteration as it will store the NTT results in `bram1`
    -- this way there can be decoded/sampled new polynomials while the computation is happening
    bram0: entity work.bram
    generic map (
        DATA_WIDTH => 192,
        DATA_DEPTH => 512,
        OUT_DELAY => BRAM_DELAY
    )
    port map (
        clk => clk,

        wea => bram0_wea,
        reb => bram0_reb,

        dina => bram0_dina_ser,
        doutb => bram0_doutb_ser,

        addra => bram0_addra,
        addrb => bram0_addrb
    );

    bram0_dina_ser <= slv_array_ser(bram0_dina, 2, 96);
    bram0_doutb <= slv_array_deser(bram0_doutb_ser, 2, 96);

    bram0_wea <= (((bram0_storing_s1s2 or bram0_storing_y) and sec_conversion_m_axis_tvalid) or ((not bram0_storing_s1s2) and compress_m_axis_tvalid and compress_mode_decompress) or ((not (bram0_storing_y and sec_conversion_has_pending_transactions)) and sample_m_axis_tvalid) or sample_in_ball_m_axis_tvalid or (poly_mul_first_bram_only and poly_mul_coeffs_wea)) and bram0_can_write and not bram1_take_bram0;
    bram0_reb <= (bram1_reading_vld or (not poly_mul_read_bram_mux));

    bram0_dina <= sec_conversion_m_axis_tdata_modified when ((bram0_storing_s1s2 or bram0_storing_y) and sec_conversion_m_axis_tvalid) = '1' else
        (1 => (others => '0'), 0 => compress_m_axis_tdata) when (compress_m_axis_tvalid and compress_mode_decompress) = '1' else
        sample_m_axis_tdata when sample_m_axis_tvalid = '1' else
        (1 => (others => '0'), 0 => sample_in_ball_m_axis_tdata) when sample_in_ball_m_axis_tvalid = '1' else
        poly_mul_coeffs_dina;

    bram0_addra <= bram0_addra_reg(8 downto 6) & poly_mul_coeffs_addra(5 downto 0) when (poly_mul_first_bram_only and poly_mul_coeffs_wea) = '1' else bram0_addra_reg;
    bram0_addrb <= bram0_addrb_offset(3 downto 1) & (bram0_addrb_offset(0) xor (is_dilithium and bram1_addrb(5))) & bram1_addrb(4 downto 0) when bram1_reading_vld = '1' and (bram1_mode = "0000" or bram1_mode = "1010" or bram1_mode = "1011" or bram1_mode = "1100") else
        bram0_addrb_offset(3 downto 1) & (bram0_addrb_offset(0) xor (is_dilithium and poly_mul_coeffs_addrb(5))) & poly_mul_coeffs_addrb(4 downto 0);

    proc_bram0_can_write: process(all) is
        variable can_write: std_logic;
    begin
        can_write := '0';
        for i in 0 to 7 loop
            can_write := can_write or not bram0_polys_vld(2 * i) or (not bram0_polys_vld(2 * i + 1) and not is_dilithium);
        end loop;

        -- TODO: remove dependency on sampling
        bram0_can_write <= can_write when mode(6) = '0' or sample_m_axis_tuser(1 downto 0) = "00" else can_write and not (sample_m_axis_tvalid and poly_mul_running);
    end process;

    bram0_addra_reg_last <= (and bram0_addra_reg(5 downto 0)) when is_dilithium = '1' else (and bram0_addra_reg(4 downto 0));
    bram0_addrb_last <= (and bram0_addrb(5 downto 0)) when is_dilithium = '1' else (and bram0_addrb(4 downto 0));

    bram0_storing_s1s2 <= '1' when sec_conversion_mode_out = "0000" else '0';
    bram0_storing_y <= '1' when sec_conversion_mode_out = "0001" else '0';

    proc_bram0: process(clk) is
    begin
        if rising_edge(clk) then
            if (not running or sig_invalid) = '1' then
                bram0_addra_reg <= (others => '0');
                bram0_polys_vld <= (others => '0');

                bram0_addrb_offset <= (others => '0');
            else
                if bram0_wea = '1' then
                    if (poly_mul_first_bram_only and poly_mul_coeffs_wea) = '1' then
                        -- indicate valid polynomial if we write last coefficients
                        bram0_polys_vld(to_integer(unsigned(bram0_addra_reg(8 downto 6) & (not is_dilithium and bram0_addra_reg(5))))) <= poly_mul_coeffs_addra_last and poly_mul_last_iteration;
                    else
                        -- indicate valid polynomial if we write last coefficients
                        bram0_polys_vld(to_integer(unsigned(bram0_addra_reg(8 downto 6) & (not is_dilithium and bram0_addra_reg(5))))) <= bram0_addra_reg_last;

                        bram0_addra_reg <= std_logic_vector(unsigned(bram0_addra_reg) + 1);
                    end if;
                end if;

                -- `bram0` is read mostly from `poly_mul`, only during dilithium key_gen it reads at the same time as `bram1`
                if ((bram1_reading_vld or (not poly_mul_read_bram_mux and not poly_mul_repeat_read)) and bram0_addrb_last) = '1' then
                    -- indicate read polynomial
                    bram0_polys_vld(to_integer(unsigned(bram0_addrb_offset))) <= '0';

                    -- when NTT is stored back in `bram0` we increase only offset during first iteration
                    if (not poly_mul_first_bram_only or poly_mul_first_iteration) = '1' then
                        -- offset represents 32 memory locations, for dilithium's polynomial we need 64, for kyber's 32
                        if is_dilithium = '1' then
                            bram0_addrb_offset <= std_logic_vector(unsigned(bram0_addrb_offset) + 2);
                        else
                            bram0_addrb_offset <= std_logic_vector(unsigned(bram0_addrb_offset) + 1);
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- main memory, storing polynomials that are needed for computations
    -- memory offsets:
    -- dilithium - key_gen
    -- 0 -> s1
    -- L -> s2
    -- K + L -> NTT(s1) -> t0
    -- 2 * (K + L) -> t
    -- dilithium - sign:
    -- 0 -> s1
    -- L -> s2
    -- K + L -> t0
    -- 2 * K + L -> y -> y + cs1
    -- 2 * (K + L) -> NTT(w) -> w - cs2
    -- 3 * K + 2 * L -> w -> ct0
    -- dilithium - verify:
    -- 0 -> t1
    -- K -> z
    -- 2 * (K + L) -> w
    -- kyber - pke_key_gen, kem_key_gen:
    -- 0 -> s
    -- K -> e -> A * s + e
    -- 2 * K -> A * s - first part mul (c)
    -- 3 * K -> A * s - first part mul (d)
    -- kyber - pke_dec, kem_dec:
    -- 0 -> s
    -- 2 * K -> u -> s * u - first part mul (c) -> w
    -- 5 * K -> s * u - first part mul (d)
    -- kyber - pke_enc, kem_enc, kem_dec:
    -- K -> t
    -- 2 * K -> m
    -- 2 * K + 1 -> r -> v
    -- 3 * K + 1 -> u
    -- 4 * K + 1 -> A * t - first part mul (c)
    -- 5 * K + 1 -> A * t - first part mul (d)
    -- -----------------
    bram1: entity work.bram
    generic map (
        DATA_WIDTH => 192,
        DATA_DEPTH => 4096,
        OUT_DELAY => BRAM_DELAY
    )
    port map (
        clk => clk,

        wea => bram1_wea,
        reb => bram1_reb,

        dina => bram1_dina_ser,
        doutb => bram1_doutb_ser,

        addra => bram1_addra,
        addrb => bram1_addrb
    );

    bram1_dina_ser <= slv_array_ser(bram1_dina, 2, 96);
    bram1_doutb <= slv_array_deser(bram1_doutb_ser, 2, 96);

    bram1_wea <= sample_m_axis_tvalid when bram1_copy_bram0 = '1' else
        sec_conversion_m_axis_tvalid when (bram1_store_kyber_s or bram1_store_kyber_m) = '1' else
        compress_m_axis_tvalid when bram1_store_kyber_t = '1' else
        compress_m_axis_tvalid and encode_s_axis_tready(0) when (compress_mode_high_bits and mode(6)) = '1' else
        poly_mul_coeffs_wea and ((poly_mul_offset_we(0) and not poly_mul_coeffs_addra_mux) or (poly_mul_offset_we(1) and poly_mul_coeffs_addra_mux));

    bram1_reb <= bram1_reading_vld or not poly_mul_rdy;

    bram1_dina <= sample_m_axis_tdata when bram1_copy_bram0 = '1' else
        sec_conversion_m_axis_tdata when (bram1_store_kyber_s or bram1_store_kyber_m) = '1' else
        poly_mul_coeffs_dina when poly_mul_running = '1' else
        (1 => (95 downto 0 => '0'), 0 => compress_m_axis_low_bits_tdata) when mode(6) = '1' else
        (1 => (95 downto 0 => '0'), 0 => compress_m_axis_tdata);

    bram1_addra <= bram1_addra_reg when (bram1_copy_bram0 or (compress_mode_high_bits and mode(6)) or bram1_store_kyber_s or bram1_store_kyber_t or bram1_store_kyber_m) = '1' else
        poly_mul_addra_offset1 & (is_dilithium and poly_mul_coeffs_addra(5)) & poly_mul_coeffs_addra(4 downto 0) when poly_mul_coeffs_addra_mux = '1' else
        poly_mul_addra_offset0 & (is_dilithium and poly_mul_coeffs_addra(5)) & poly_mul_coeffs_addra(4 downto 0);

    bram1_addrb <=
        bram1_addrb_offset & bram1_addrb_reg when bram1_reading_vld = '1' else
        poly_mul_addrb_offset1 & (is_dilithium and poly_mul_coeffs_addrb(5)) & poly_mul_coeffs_addrb(4 downto 0) when (poly_mul_coeffs_addrb_mux or poly_mul_first_iteration) = '1' else
        poly_mul_addrb_offset0 & (is_dilithium and poly_mul_coeffs_addrb(5)) & poly_mul_coeffs_addrb(4 downto 0);

    bram1_state_machine: entity work.bram1_state_machine
    port map (
        clk => clk,
        rst => not running or sig_invalid,

        mode => mode,

        param_k => param_k,
        param_l => param_l,

        next_mode => bram1_reading_vld and bram1_addrb_reg_second_to_last,

        bram1_mode => bram1_mode,
        bram1_addrb_offset => bram1_addrb_offset
    );

    -- copies s1, s2 coefficients during dilithium's key_gen
    bram1_copy_bram0 <= '1' when (mode(6) and sample_m_axis_tvalid and not poly_mul_running) = '1' and sample_s_axis_tuser(1 downto 0) /= "00" else '0';

    -- takes s coefficients during kyber's pke_dec, kem_dec and t, m coefficients during kyber's pke_enc, kem_enc
    bram1_take_bram0 <= '1' when ((mode(1) or mode(4) or mode(5)) and (not bram1_stored_kyber_t)) = '1' else '0';

    bram1_reading_vld <= '0' when bram1_mode = "0000" and unsigned(bram1_addra_reg(11 downto 6)) < param_k + param_l else
        poly_mul_finished when bram1_mode = "1101" or bram1_mode = "0101" else
        -- TODO: reduce delay by checking if fifo is almost full
        poly_mul_first_bram_only and (not coeffs_fifo0_dout_vld or (or bram1_addrb_reg)) when bram1_mode = "0011" else
        poly_mul_half_finished and (not coeffs_fifo0_dout_vld or (or bram1_addrb_reg)) and (or bram0_polys_vld) when mode(5) = '1' and bram1_mode = "1010" else
        poly_mul_finished and (not coeffs_fifo0_dout_vld or (or bram1_addrb_reg)) and (or bram0_polys_vld) when bram1_mode = "1010" else
        poly_mul_finished and (not coeffs_fifo0_dout_vld or (or bram1_addrb_reg));

    bram1_addra_reg_kyber_last <= (and bram1_addra_reg(4 downto 0)) and not is_dilithium;
    bram1_addrb_reg_last <= (and bram1_addrb_reg) when is_dilithium = '1' else (and bram1_addrb_reg(4 downto 0));
    bram1_addrb_reg_second_to_last <= '1' when (not is_dilithium or bram1_addrb_reg(5)) & bram1_addrb_reg(4 downto 0) = "111110" else '0';

    bram1_store_kyber_s <= sec_conversion_m_axis_tvalid and (not bram1_stored_kyber_s) and (mode(2) or mode(5));
    bram1_store_kyber_t <= compress_m_axis_tvalid and (not bram1_stored_kyber_t) and (mode(1) or mode(4) or (bram1_stored_kyber_s and mode(5)));
    bram1_store_kyber_m <= sec_conversion_m_axis_tvalid and (not bram1_stored_kyber_m) and (poly_mul_half or mode(1) or mode(4)) when sec_conversion_mode_out /= "1001" and sec_conversion_mode_out /= "1000" else '0';

    proc_bram1: process(clk) is
    begin
        if rising_edge(clk) then
            if (not running or sig_invalid) = '1' then
                bram1_mode_shift_reg <= (others => (others => '1'));

                -- for kyber pke_enc and kem_enc coefficients are stored from K offset, it is need because for kem_dec is needed both pke_dec and pke_enc and pke_dec starts at offset 0
                bram1_addra_reg <= std_logic_vector(to_unsigned(param_k, 6)) & (5 downto 0 => '0') when (mode(1) or mode(4)) = '1' else (others => '0');
                bram1_addrb_reg <= (others => '0');

                bram1_stored_kyber_m <= '0';
                bram1_stored_kyber_s <= '0';
                bram1_stored_kyber_t <= '0';
            else
                bram1_mode_shift_reg <= (bram1_mode or (3 downto 0 => not bram1_reading_vld)) & bram1_mode_shift_reg(bram1_mode_shift_reg'left downto 1);

                if (bram1_store_kyber_s and bram1_addra_reg_kyber_last) = '1' and unsigned(bram1_addra_reg(7 downto 6)) = param_k - 1 then
                    bram1_stored_kyber_s <= '1';
                end if;

                if (bram1_store_kyber_t and bram1_addra_reg_kyber_last) = '1' and unsigned(bram1_addra_reg(8 downto 6)) = 2 * param_k - 1 then
                    bram1_stored_kyber_t <= '1';
                end if;

                if (bram1_store_kyber_m and bram1_addra_reg_kyber_last) = '1' then
                    bram1_stored_kyber_m <= '1';
                end if;

                if (bram1_wea and (bram1_copy_bram0 or bram1_take_bram0 or (compress_mode_high_bits and mode(6)) or bram1_store_kyber_s or bram1_store_kyber_t or bram1_store_kyber_m)) = '1' then
                    if bram1_addra_reg_kyber_last = '1' then
                        bram1_addra_reg <= std_logic_vector(unsigned(bram1_addra_reg) + 33);
                    else
                        bram1_addra_reg <= std_logic_vector(unsigned(bram1_addra_reg) + 1);
                    end if;
                end if;

                if bram1_reading_vld = '1' then
                    if bram1_addrb_reg_last = '1' then
                        bram1_addrb_reg <= (others => '0');
                    else
                        bram1_addrb_reg <= std_logic_vector(unsigned(bram1_addrb_reg) + 1);
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- small fifo for short term coefficients storing
    -- it is used for polynomial addition/subtraction, dumping from memory

    coeffs_fifo0: entity work.small_fifo
    generic map (
        -- 95 downto 0 coefficients share 0
        -- 191 downto 96 coefficients share 1
        -- 215 downto 192 high bits
        -- 219 downto 216 identification of coefficients (based on this different types of compression are performed)
        DATA_WIDTH => 220,
        DATA_DEPTH => 64,
        OUT_REG => true
    )
    port map (
        clk => clk,
        rst => not running or sig_invalid,

        din => coeffs_fifo0_din_ser,
        din_vld => coeffs_fifo0_din_vld,

        dout => coeffs_fifo0_dout_ser,
        dout_vld => coeffs_fifo0_dout_vld,
        dout_rdy => coeffs_fifo0_dout_rdy
    );

    coeffs_fifo0_din_ser <= coeffs_fifo0_mode_din & coeffs_fifo0_high_bits_din & slv_array_ser(coeffs_fifo0_din, 2, 96);

    coeffs_fifo0_mode_dout <= coeffs_fifo0_dout_ser(219 downto 216);
    coeffs_fifo0_high_bits_dout <= coeffs_fifo0_dout_ser(215 downto 192);
    coeffs_fifo0_dout <= slv_array_deser(coeffs_fifo0_dout_ser(191 downto 0), 2, 96);

    proc_coeffs_fifo0_in: process(clk) is
    begin
        if rising_edge(clk) then
            coeffs_fifo0_high_bits_din <= (others => '0');

            -- store coefficients from bram for inplace addition/subtraction with results of polynomial multiplication
            if poly_mul_coeffs_fifo0_mode_in = "001" or poly_mul_coeffs_fifo0_mode_in = "010" then
                coeffs_fifo0_din_vld <= coeffs_fifo0_vld(0);

                if coeffs_fifo0_vld(0) = '1' then
                    coeffs_fifo0_mode_din <= "1111";
                    coeffs_fifo0_din <= bram1_doutb;
                end if;
            -- TODO: find out what does this do, it is something in kyber pke_dec and pke_enc
            elsif poly_mul_coeffs_fifo0_mode_out(2) = '1' then
                coeffs_fifo0_din_vld <= bram1_wea;

                if bram1_wea = '1' then
                    coeffs_fifo0_mode_din <= "1111";
                    coeffs_fifo0_din <= poly_mul_coeffs_dina;
                end if;
            -- store coefficients from `bram1` before outputing or when they should be added to other coefficients
            elsif bram1_mode_shift_reg(0) /= "1111" and bram1_mode_shift_reg(0) /= "0101" then
                coeffs_fifo0_mode_din <= bram1_mode_shift_reg(0);
                coeffs_fifo0_din_vld <= '1';

                for i in 0 to 1 loop
                    for j in 0 to 3 loop
                        case bram1_mode_shift_reg(0) is
                            when "0000" | "1011" | "1100" => coeffs_fifo0_din(i)(23 + 24 * j downto 24 * j) <= add_reduce(bram0_doutb(i)(23 + 24 * j downto 24 * j), bram1_doutb(i)(23 + 24 * j downto 24 * j), is_dilithium);
                            when "1010" => coeffs_fifo0_din(i)(23 + 24 * j downto 24 * j) <= kyber_sub_reduce(bram0_doutb(i)(23 + 24 * j downto 12 + 24 * j), bram1_doutb(i)(23 + 24 * j downto 12 + 24 * j)) & kyber_sub_reduce(bram0_doutb(i)(11 + 24 * j downto 24 * j), bram1_doutb(i)(11 + 24 * j downto 24 * j));
                            when "1101" => coeffs_fifo0_din(i)(23 + 24 * j downto 24 * j) <= kyber_add_reduce(coeffs_fifo0_dout(i)(23 + 24 * j downto 12 + 24 * j), bram1_doutb(i)(23 + 24 * j downto 12 + 24 * j)) & kyber_add_reduce(coeffs_fifo0_dout(i)(11 + 24 * j downto 24 * j), bram1_doutb(i)(11 + 24 * j downto 24 * j));
                            when others => coeffs_fifo0_din(i)(23 + 24 * j downto 24 * j) <= bram1_doutb(i)(23 + 24 * j downto 24 * j);
                        end case;
                    end loop;
                end loop;
            else
                coeffs_fifo0_din_vld <= '0';
            end if;

            if sig_invalid = '1' then
                coeffs_fifo0_din_vld <= '0';
            end if;
        end if;
    end process;

    proc_coeffs_fifo0_out: process(all) is
    begin
        coeffs_fifo0_dout_rdy <= '0';

        -- stored coefficients for in-place addition/subtraction during polynomial multiplication
        if (poly_mul_coeffs_fifo0_mode_out(1 downto 0) = "01" or poly_mul_coeffs_fifo0_mode_out(1 downto 0) = "10" or poly_mul_coeffs_fifo0_mode_out(1 downto 0) = "11") and poly_mul_offset_we /= "11" then
            coeffs_fifo0_dout_rdy <= poly_mul_inplace_next;
        -- unmask t for power2round
        elsif coeffs_fifo0_mode_dout = "0000" then
            coeffs_fifo0_dout_rdy <= (not unmasked_coeffs_in_vld_r) or (not unmasked_coeffs_vld) or unmasked_coeffs_next;
        -- a2b s1, s2 when outputing
        elsif coeffs_fifo0_mode_dout = "0001" then
            coeffs_fifo0_dout_rdy <= sec_conversion_s_axis_tready;
        -- stored ct0, before summed with w - cs2
        elsif coeffs_fifo0_mode_dout = "0100" then
            coeffs_fifo0_dout_rdy <= sec_decompose_m_axis_tvalid;
        -- unmask z when outputing
        elsif coeffs_fifo0_mode_dout = "0110" then
            coeffs_fifo0_dout_rdy <= (not unmasked_coeffs_in_vld_r) or (not unmasked_coeffs_vld) or unmasked_coeffs_next;
        -- stored v + e2 before summing with m
        elsif coeffs_fifo0_mode_dout = "1100" then
            if bram1_mode_shift_reg(0) = "1101" then
                coeffs_fifo0_dout_rdy <= '1';
            end if;
        -- masked decoding of message m
        elsif coeffs_fifo0_mode_dout = "1010" then
            coeffs_fifo0_dout_rdy <= sec_decoder_s_axis_tready;
        -- unmask t when outputing
        elsif coeffs_fifo0_mode_dout = "1000" then
            coeffs_fifo0_dout_rdy <= (not unmasked_coeffs_in_vld_r) or (not unmasked_coeffs_vld) or unmasked_coeffs_next;
        -- a2b s when outputing
        elsif coeffs_fifo0_mode_dout = "1001" then
            coeffs_fifo0_dout_rdy <= sec_conversion_s_axis_tready;
        -- unmask u, v when outputing
        elsif coeffs_fifo0_mode_dout = "1011" or coeffs_fifo0_mode_dout = "1101" then
            -- comparing ciphertext
            if mode(5) = '1' then
                coeffs_fifo0_dout_rdy <= sec_decompressed_comparison_s_axis_tready and sec_decompressed_comparison_re_encrypted;
            -- outputing ciphertext
            else
                coeffs_fifo0_dout_rdy <= (not unmasked_coeffs_in_vld_r) or (not unmasked_coeffs_vld) or unmasked_coeffs_next;
            end if;
        -- compute high bits of w (during sign it is masked and computed using `sec_decompose`)
        elsif mode(7) = '1' and (coeffs_fifo0_mode_dout = "0011" or coeffs_fifo0_mode_dout = "0111") then
            coeffs_fifo0_dout_rdy <= sec_decompose_s_axis_tready;
        -- for all other valid modes data are fed to `compress` unit
        elsif coeffs_fifo0_mode_dout /= "1111" then
            coeffs_fifo0_dout_rdy <= compress_s_axis_tready;
        end if;
    end process;

    proc_coeffs_fifo0: process(clk) is
    begin
        if rising_edge(clk) then
            if (not running or sig_invalid) = '1' then
                coeffs_fifo0_vld <= (others => '0');
            else
                coeffs_fifo0_vld <= (poly_mul_coeffs_addrb_mux and (not poly_mul_bram_mux_reg)) & coeffs_fifo0_vld(coeffs_fifo0_vld'left downto 1);
            end if;
        end if;
    end process;

    -- bigger fifo for short term coefficients storing
    -- it is used to store ciphertext and computed polynomials when processing by slower secure components in dilithium

    coeffs_fifo1: entity work.small_fifo
    generic map (
        DATA_WIDTH => 194,
        DATA_DEPTH => 512,
        OUT_REG => true
    )
    port map (
        clk => clk,
        rst => not running or sig_invalid,

        din => coeffs_fifo1_din_ser,
        din_vld => coeffs_fifo1_din_vld,

        dout => coeffs_fifo1_dout_ser,
        dout_vld => coeffs_fifo1_dout_vld,
        dout_rdy => coeffs_fifo1_dout_rdy
    );

    coeffs_fifo1_din_ser <= coeffs_fifo1_mode_din & slv_array_ser(coeffs_fifo1_din, 2, 96);

    coeffs_fifo1_mode_dout <= coeffs_fifo1_dout_ser(193 downto 192);
    coeffs_fifo1_dout <= slv_array_deser(coeffs_fifo1_dout_ser(191 downto 0), 2, 96);

    coeffs_fifo1_p: process(all) is
    begin
        coeffs_fifo1_din <= (others => (others => '0'));
        coeffs_fifo1_mode_din <= "00";

        -- compensate that `sec_bound_check` and `sec_decompose` components can't accept coefficients each cycle
        if is_dilithium = '1' then
            if (sec_decompose_m_axis_tvalid and (and poly_mul_next_bound_check_mode) and (not poly_mul_running)) = '1' then
                coeffs_fifo1_mode_din <= "00";
                coeffs_fifo1_din_vld <= '1';
                coeffs_fifo1_din <= sec_decompose_m_axis_low_bits_tdata;
            elsif bram1_mode_shift_reg(0) = "0101" then
                coeffs_fifo1_mode_din <= "10";
                coeffs_fifo1_din_vld <= '1';
                coeffs_fifo1_din <= bram1_doutb;
            else
                coeffs_fifo1_din <= poly_mul_coeffs_dina;
                coeffs_fifo1_mode_din <= poly_mul_bound_check_mode;
                coeffs_fifo1_din_vld <= poly_mul_coeffs_wea and poly_mul_last_iteration and (or poly_mul_bound_check_mode);
            end if;

            if coeffs_fifo1_mode_dout = "10" then
                coeffs_fifo1_dout_rdy <= sec_decompose_s_axis_tready;
            else
                coeffs_fifo1_dout_rdy <= sec_bound_check_s_axis_tready;
            end if;
        -- store ciphertext during decapsulation
        else
            coeffs_fifo1_din(0) <= compress_m_axis_tdata;
            coeffs_fifo1_din_vld <= compress_m_axis_tvalid when compress_m_axis_tuser = "010001" or compress_m_axis_tuser = "010010" or compress_m_axis_tuser = "010011" or compress_m_axis_tuser = "010100" else '0';

            coeffs_fifo1_dout_rdy <= sec_decompressed_comparison_s_axis_tready and (not sec_decompressed_comparison_re_encrypted);
        end if;
    end process;

    -- validity checks for dilithium

    bound_check: entity work.bound_check
    port map (
        clk => clk,
        rst => not running,

        mode => mode(10 downto 9),

        coeffs => compress_m_axis_tdata,
        coeffs_vld => bound_check_coeffs_vld,

        in_bound => bound_check_in_bound,
        in_bound_vld => bound_check_in_bound_vld
    );

    -- check z ≥ gamma1 - beta during verify
    bound_check_coeffs_vld <= compress_m_axis_tvalid when mode(8) = '1' and compress_m_axis_tuser(5 downto 1) = "01100" else '0';

    sec_bound_check_i: entity work.sec_bound_check
    port map (
        clk => clk,
        rst => (not running) or sig_invalid,

        conversion_bound_check_mode => sec_bound_check_conversion_bound_check_mode,

        conversion_s_axis_tdata => sec_bound_check_conversion_s_axis_tdata,
        conversion_s_axis_tvalid => sec_bound_check_conversion_s_axis_tvalid,
        conversion_s_axis_tready => sec_bound_check_conversion_s_axis_tready,

        conversion_m_axis_tdata => sec_bound_check_conversion_m_axis_tdata,
        conversion_m_axis_tvalid => sec_bound_check_conversion_m_axis_tvalid,

        s_axis_tdata => sec_bound_check_s_axis_tdata,
        s_axis_tuser => sec_bound_check_s_axis_tuser,
        s_axis_tvalid => sec_bound_check_s_axis_tvalid,
        s_axis_tready => sec_bound_check_s_axis_tready,

        invalid => sec_bound_check_invalid,
        invalid_vld => sec_bound_check_invalid_vld
    );

    with sec_conversion_mode_in select sec_bound_check_conversion_s_axis_tready <=
        sec_conversion_s_axis_tready when "0011" | "0101" | "0110",
        '0' when others;

    sec_bound_check_conversion_m_axis_tdata <= sec_conversion_m_axis_tdata;
    with sec_conversion_mode_out select sec_bound_check_conversion_m_axis_tvalid <=
        sec_conversion_m_axis_tvalid when "0011" | "0101" | "0110",
        '0' when others;

    sec_bound_check_in_p: process(all) is
    begin
        sec_bound_check_s_axis_tdata <= coeffs_fifo1_dout;
        sec_bound_check_s_axis_tvalid <= is_dilithium and coeffs_fifo1_dout_vld;

        case coeffs_fifo1_mode_dout is
            -- check r0 ≥ gamma2 - beta during sign
            when "00" => sec_bound_check_s_axis_tuser <= mode(10 downto 9) & "01";
            -- check z ≥ gamma1 - beta during sign
            when "01" => sec_bound_check_s_axis_tuser <= mode(10 downto 9) & "00";
            -- check ct0 ≥ gamma2 during sign
            when "11" => sec_bound_check_s_axis_tuser <= mode(10 downto 9) & "10";
            when others =>
                sec_bound_check_s_axis_tuser <= "0000";
                sec_bound_check_s_axis_tvalid <= '0';
        end case;
    end process;

    -- make_hint for dilithium

    make_hint: entity work.make_hint
    port map (
        clk => clk,
        rst => not running or sig_invalid,

        mode => mode(10 downto 9),

        coeffs_high_bits => make_hint_coeffs_high_bits,
        coeffs => make_hint_coeffs,
        coeffs_vld => make_hint_coeffs_vld,

        m_axis_tdata => make_hint_m_axis_tdata,
        m_axis_tuser => make_hint_m_axis_tuser,
        m_axis_tvalid => make_hint_m_axis_tvalid,
        m_axis_tready => make_hint_m_axis_tready
    );

    gen_make_hint_in: for i in 0 to 3 generate
        -- should be safe to unmask here based on https://eprint.iacr.org/2022/1406.pdf
        make_hint_coeffs(23 + 24 * i downto 24 * i) <= dilithium_add_reduce(make_hint_coeffs_arr(0)(23 + 24 * i downto 24 * i), make_hint_coeffs_arr(1)(23 + 24 * i downto 24 * i));
    end generate;

    make_hint_p: process(clk) is
    begin
        if rising_edge(clk) then
            make_hint_coeffs_high_bits <= sec_decompose_m_axis_tdata;
            make_hint_coeffs_vld <= coeffs_fifo0_dout_vld and sec_decompose_m_axis_tvalid when coeffs_fifo0_mode_dout = "0100" else '0';

            if (coeffs_fifo0_dout_vld and sec_decompose_m_axis_tvalid) = '1' and coeffs_fifo0_mode_dout = "0100" then
                for i in 0 to 3 loop
                    make_hint_coeffs_arr(0)(23 + 24 * i downto 24 * i) <= dilithium_add_reduce(coeffs_fifo0_dout(0)(23 + 24 * i downto 24 * i), sec_decompose_m_axis_low_bits_tdata(0)(23 + 24 * i downto 24 * i));
                    make_hint_coeffs_arr(1)(23 + 24 * i downto 24 * i) <= dilithium_add_reduce(coeffs_fifo0_dout(1)(23 + 24 * i downto 24 * i), sec_decompose_m_axis_low_bits_tdata(1)(23 + 24 * i downto 24 * i));
                end loop;
            end if;
        end if;
    end process;

    make_hint_m_axis_tready <= '1' when make_hint_m_axis_tuser = '1' else m_axis_tready when out_mode(2) = '1' else '0';

    use_hint: entity work.use_hint
    port map (
        clk => clk,
        rst => not running,

        mode => mode(10 downto 9),

        s_axis_tdata => use_hint_s_axis_tdata,
        s_axis_tvalid => use_hint_s_axis_tvalid,
        s_axis_tready => use_hint_s_axis_tready,

        m_axis_tdata => use_hint_m_axis_tdata,
        m_axis_tvalid => use_hint_m_axis_tvalid,
        m_axis_tready => use_hint_m_axis_tready,

        hints_invalid => use_hint_hints_invalid
    );

    gen_use_hint_in: for i in 0 to 3 generate
        use_hint_s_axis_tdata(15 + 16 * i downto 16 * i) <= (use_hint_s_axis_shares_tdata_r(0)(15 + 16 * i downto 16 * i) xor use_hint_s_axis_shares_tdata_r(1)(15 + 16 * i downto 16 * i)) when use_hint_s_axis_shares_tvalid_r = '1' else
            compress_m_axis_low_bits_tdata(22 + 24 * i) & (14 downto 6 => '0') & compress_m_axis_tdata(5 + 24 * i downto 24 * i);
    end generate;

    use_hint_s_axis_tvalid <= use_hint_s_axis_shares_tvalid_r or (compress_m_axis_tvalid and compress_mode_high_bits and mode(8));

    use_hint_m_axis_tready <= encode_s_axis_tready(0);

    -- make sure there are never secret data before combining the shares
    use_hint_p: process(clk) is
    begin
        if rising_edge(clk) then
            if (((not use_hint_s_axis_shares_tvalid_r) or use_hint_s_axis_tready) and in_mode(3) and s_axis_tvalid) = '1' then
                use_hint_s_axis_shares_tdata_r <= s_axis_tdata;
            end if;

            if rst = '1' then
                use_hint_s_axis_shares_tvalid_r <= '0';
            else
                if (in_mode(3) and s_axis_tvalid) = '1' then
                    use_hint_s_axis_shares_tvalid_r <= '1';
                elsif use_hint_s_axis_tready = '1' then
                    use_hint_s_axis_shares_tvalid_r <= '0';
                end if;
            end if;
        end if;
    end process;

    -- input logic

    in_state_machine: entity work.in_state_machine
    port map (
        clk => clk,
        rst => not running,

        mode => mode,

        next_mode => in_next_mode,

        in_mode => in_mode,
        in_decode_mode => in_decode_mode,

        in_transaction_offset => in_transaction_offset
    );

    in_next_mode <= s_axis_tvalid and in_rdy and s_axis_tlast when in_mode = "0100" else s_axis_tvalid and in_rdy;

    in_rdy <= running and (not in_mode(1) or decode_s_axis_tready(0)) and (not in_mode(2) or (keccak_s_axis_tready and not keccak_last_absorbing_iteration and keccak_source(1) and keccak_source_vld)) and (not in_mode(3) or ((not use_hint_s_axis_shares_tvalid_r) or use_hint_s_axis_tready));

    -- output logic

    out_state_machine: entity work.out_state_machine
    port map (
        clk => clk,
        rst => not running,

        mode => mode,

        next_mode => out_vld and m_axis_tready,

        out_mode => out_mode,

        out_transaction_last => out_transaction_last,

        out_transaction_offset => out_transaction_offset_tmp,
        out_pk => out_pk
    );

    -- for invalid ciphertext read invalid key
    out_transaction_offset <= 16 + out_transaction_offset_tmp when (mode(5) and (not cipher_eq)) = '1' else out_transaction_offset_tmp;

    proc_out: process(all) is
    begin
        out_data <= (others => (others => '0'));

        if running = '0' then
            out_vld <= '0';
        else
            case out_mode is
                when "001" =>
                    out_data <= current_data;
                    out_vld <= outputing;
                when "010" =>
                    out_data <= encode_m_axis_tdata;

                    if keccak_mode_in = "0011" or keccak_mode_in = "1100" then
                        out_vld <= encode_m_axis_tvalid(0) and keccak_s_axis_tready and not keccak_last_absorbing_iteration and not keccak_source(0);
                    else
                        out_vld <= encode_m_axis_tvalid(0);
                    end if;
                when others =>
                    out_data(0) <= make_hint_m_axis_tdata;
                    out_vld <= make_hint_m_axis_tvalid;
            end case;
        end if;

        -- during verify signature only one bit is required to indicate validity
        if mode(8) = '1' then
            out_data(0)(0) <= verified;
            out_vld <= verified_vld;
        end if;

        if rising_edge(clk) then
            if (mode(0) or mode(1) or mode(2)) = '1' then
                outputing <= seeds_vld;
            elsif (mode(3) or mode(6)) = '1' then
                outputing <= ((seeds_vld and out_pk) or tr_vld) and poly_mul_finished;
            elsif mode(4) = '1' then
                outputing <= poly_mul_finished;
            elsif mode(5) = '1' then
                outputing <= seeds_vld and out_pk and cipher_eq_vld;
            elsif mode(7) = '1' then
                outputing <= not make_hint_m_axis_tuser and make_hint_m_axis_tvalid;
            end if;
        end if;
    end process;

    -- verify signature validity

    proc_verify: process(clk) is
    begin
        if rising_edge(clk) then
            if running = '0' then
                verified <= '1';
                verified_vld <= '0';
            else
                -- if bound check fails, signature is invalid and will abort any further computation
                if ((not bound_check_in_bound) and bound_check_in_bound_vld) = '1' then
                    verified <= '0';
                    verified_vld <= '1';
                end if;

                -- if provided hints are not valid, signature is invalid and will abort any further computation
                if use_hint_hints_invalid = '1' then
                    verified <= '0';
                    verified_vld <= '1';
                end if;

                -- check that same challenge is reconstructed during verification
                if keccak_m_axis_tvalid = '1' and keccak_mode_out = "0111" then
                    if current_data /= keccak_m_axis_tdata then
                        verified <= '0';
                    end if;

                    verified_vld <= keccak_out_transactions_last;
                end if;

                if (verified_vld and m_axis_tready) = '1' then
                    verified_vld <= '0';
                end if;
            end if;
        end if;
    end process;

    -- for better timing, register this signal as it is used to reset multiple components
    proc_sig_invalid: process(clk) is
    begin
        if rising_edge(clk) then
            sig_invalid <= (sec_bound_check_invalid_vld and sec_bound_check_invalid) or (make_hint_m_axis_tuser and make_hint_m_axis_tvalid);
        end if;
    end process;

    -- ciphertexts comparison during FO-transform

    sec_decompressed_comparison_i: entity work.sec_decompressed_comparison
    port map (
        clk => clk,
        rst => not running,

        conversion_s_axis_tdata => sec_decompressed_comparison_conversion_s_axis_tdata,
        conversion_s_axis_tvalid => sec_decompressed_comparison_conversion_s_axis_tvalid,
        conversion_s_axis_tready => sec_decompressed_comparison_conversion_s_axis_tready,

        conversion_m_axis_tdata => sec_decompressed_comparison_conversion_m_axis_tdata,
        conversion_m_axis_tvalid => sec_decompressed_comparison_conversion_m_axis_tvalid,

        r => other_random(7 downto 0),

        re_encrypted => sec_decompressed_comparison_re_encrypted,

        s_axis_tdata => sec_decompressed_comparison_s_axis_tdata,
        s_axis_tuser => mode(10 downto 9),
        s_axis_tvalid => sec_decompressed_comparison_s_axis_tvalid,
        s_axis_tready => sec_decompressed_comparison_s_axis_tready,

        invalid => sec_decompressed_comparison_invalid,
        invalid_vld => sec_decompressed_comparison_invalid_vld
    );

    sec_decompressed_comparison_conversion_s_axis_tready <= sec_conversion_s_axis_tready;

    sec_decompressed_comparison_conversion_m_axis_tdata <= sec_conversion_m_axis_tdata;
    sec_decompressed_comparison_conversion_m_axis_tvalid <= sec_conversion_m_axis_tvalid and bram1_stored_kyber_m when sec_conversion_mode_out = "1111" else '0';

    sec_decompressed_comparison_s_axis_tdata <= coeffs_fifo0_dout when sec_decompressed_comparison_re_encrypted = '1' else coeffs_fifo1_dout;
    sec_decompressed_comparison_s_axis_tvalid <= '0' when is_dilithium else coeffs_fifo0_dout_vld when sec_decompressed_comparison_re_encrypted = '1' and (coeffs_fifo0_mode_dout = "1011" or coeffs_fifo0_mode_dout = "1101") else coeffs_fifo1_dout_vld and (not sec_decompressed_comparison_re_encrypted);

    cipher_p: process(clk) is
    begin
        if rising_edge(clk) then
            if cipher_eq_vld = '0' then
                cipher_eq <= not sec_decompressed_comparison_invalid;
                cipher_eq_vld <= sec_decompressed_comparison_invalid_vld;
            end if;

            if running = '0' then
                cipher_eq_vld <= '0';
            end if;
        end if;
    end process;

    outputed_s1_s2_p: process(clk) is
    begin
        if rising_edge(clk) then
            if running = '0' then
                s1_s2_counter <= 0;
                outputed_s1_s2 <= '0';
            else
                if (mode(6) and (not outputed_s1_s2) and (not out_pk) and sec_conversion_m_axis_tvalid and sec_conversion_m_axis_tready) = '1' and sec_conversion_m_axis_tuser = "1000" then
                    if s1_s2_counter = natural_for_sec_level(mode(10 downto 9), 511, 703, 959) then
                        outputed_s1_s2 <= '1';
                        s1_s2_counter <= 0;
                    else
                        s1_s2_counter <= s1_s2_counter + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- debugging during simulation
    proc_debug: process(all) is
    begin
        if SIMULATION then
            for i in 0 to 31 loop
                DATA_DEBUG(63 + 64 * i downto 64 * i) <= data_0(i) xor data_1(i);
            end loop;
        end if;
    end process;
end;
