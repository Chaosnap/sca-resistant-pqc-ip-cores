-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;

-- determines current mode of `poly_mul` component
entity poly_mul_state_machine is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- mode of top component
    mode: in std_logic_vector(10 downto 0);

    param_k: in natural range 2 to 8;
    param_l: in natural range 4 to 7;

    poly_mul_start: in std_logic;
    poly_mul_rdy: in std_logic;
    poly_mul_vld: in std_logic;

    sig_invalid: in std_logic;

    poly_mul_next_bound_check_mode: out std_logic_vector(1 downto 0);
    poly_mul_bound_check_mode: out std_logic_vector(1 downto 0);

    poly_mul_mode: out std_logic_vector(2 downto 0);
    -- indicates if and how should coeffs be used with fifo
    -- 2 - 0 => use `bram1_doutb`, 1 => use `poly_mul_coeffs_dina`
    -- 1 downto 0 indicates
    -- 00 - no fifo
    -- 01 - current coefficients in memory will be stored in fifo for in place addition
    -- 10 - current coefficients in memory will be stored in fifo for in place subtraction
    -- 11 - output of INTT will be stored in fifo with specified addresses to reorder it for compression
    poly_mul_coeffs_fifo_mode_in: out std_logic_vector(2 downto 0);
    poly_mul_coeffs_fifo_mode_out: out std_logic_vector(2 downto 0);

    -- determines which bram is used during first iteration of NTT/INTT
    poly_mul_bram_mux: out std_logic;

    -- indicates that bram0 should be used during all iterations of NTT/INTT
    poly_mul_first_bram_only: out std_logic;
    -- indicates that polynomial should not be invalidated after reading
    poly_mul_repeat_read: out std_logic;

    -- determines whether coefficients are split to shares
    -- used only during multiplication, 0 means first coefficients have shares, 1 means second coefficients have shares
    poly_mul_has_shares: out std_logic_vector(1 downto 0);

    -- determines if write should be enabled for offsets
    poly_mul_offset_we: out std_logic_vector(1 downto 0);
    -- determines memory offsets for coefficients writing
    poly_mul_addra_offset0: out std_logic_vector(5 downto 0);
    poly_mul_addra_offset1: out std_logic_vector(5 downto 0);
    -- determines memory offsets for coefficients reading
    poly_mul_addrb_offset0: out std_logic_vector(5 downto 0);
    poly_mul_addrb_offset1: out std_logic_vector(5 downto 0);

    poly_mul_running: out std_logic;
    poly_mul_half: out std_logic;
    poly_mul_half_finished: out std_logic;
    poly_mul_finished: out std_logic
);
end;

architecture behav of poly_mul_state_machine is
    type repeats_t is array(integer range <>) of natural range 0 to 23;

    -- holds info about how many times this sequence was already repeated
    -- it is indexed by `repeat_index_offset` as this should be always unique for given sequence
    signal repeats_in, repeats_out: repeats_t(0 to 1);
    signal repeats_target: repeats_t(0 to 1);

    signal poly_mul_start_reg: std_logic;
    -- `poly_mul` can start before outputing all previous coefficients, so keep track whether it was started before or after previous run finish
    signal started_count: natural range 0 to 2;

    subtype state_t is natural range 0 to 1000;
    signal state_in, state_out, initial_state: state_t;

    signal state_last: std_logic;
begin
    with mode(8 downto 0) select initial_state <=
        0 when "001000000", -- dilithium - key_gen
        3 when "010000000", -- dilithium - sign
        14 when "100000000", -- dilithium - verify
        21 when "000000001" | "000001000", -- kyber - pke_key_gen, kem_key_gen
        25 when "000000100" | "000100000", -- kyber - pke_dec, kem_dec
        29 when "000000010" | "000010000", -- kyber - pke_enc, kem_enc
        0 when others;

    process(all) is
    begin
        case state_in is
            -- dilithium - key_gen
            -- NTT(s1)
            when 0 =>
                poly_mul_mode <= "100";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "11";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- A * s1
            when 1 =>
                poly_mul_mode <= "110";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "01";
                repeats_target <= (param_k - 1, param_l - 1);
                poly_mul_half <= '0';
                state_last <= '0';
            -- INTT(A * s1)
            when 2 =>
                poly_mul_mode <= "101";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "11";
                repeats_target <= (param_k - 1, 0);
                poly_mul_half <= '0';
                state_last <= '1';
            -- dilithium - sign
            -- NTT(s1), NTT(s2), NTT(t0)
            when 3 =>
                poly_mul_mode <= "100";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "11";
                repeats_target <= (2 * param_k + param_l - 1, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- NTT(y)
            when 4 =>
                poly_mul_mode <= "100";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "11";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- A * y
            when 5 =>
                poly_mul_mode <= "110";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "01";
                repeats_target <= (param_k - 1, param_l - 1);
                poly_mul_half <= '0';
                state_last <= '0';
            -- INTT(A * y)
            when 6 =>
                poly_mul_mode <= "101";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "11";
                repeats_target <= (param_k - 1, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- NTT(c)
            when 7 =>
                poly_mul_mode <= "100";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "00";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- y + c * s1
            when 8 =>
                poly_mul_mode <= "110";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "01";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- INTT(y + c * s1)
            when 9 =>
                poly_mul_mode <= "101";
                poly_mul_next_bound_check_mode <= "01";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "11";
                repeats_target <= (0, param_l - 1);
                poly_mul_half <= '0';
                state_last <= '0';
            -- w - c * s2
            when 10 =>
                poly_mul_mode <= "110";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "01";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- INTT(w - c * s2)
            when 11 =>
                poly_mul_mode <= "101";
                poly_mul_next_bound_check_mode <= "10";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "11";
                repeats_target <= (0, param_k - 1);
                poly_mul_half <= '0';
                state_last <= '0';
            -- c * t0
            when 12 =>
                poly_mul_mode <= "110";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "00";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- INTT(c * t0)
            when 13 =>
                poly_mul_mode <= "101";
                poly_mul_next_bound_check_mode <= "11";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "00";
                repeats_target <= (0, param_k - 1);
                poly_mul_half <= '0';
                state_last <= '1';
            -- dilithium - verify
            -- NTT(t1)
            when 14 =>
                poly_mul_mode <= "100";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "00";
                repeats_target <= (param_k - 1, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- NTT(z)
            when 15 =>
                poly_mul_mode <= "100";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "00";
                repeats_target <= (param_l - 1, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- A * z - split accross two states for smaller repeats counts
            when 16 =>
                poly_mul_mode <= "110";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "00";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- A * z
            when 17 =>
                poly_mul_mode <= "110";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "00";
                repeats_target <= (param_k - 2, param_l - 1);
                poly_mul_half <= '0';
                state_last <= '0';
            -- NTT(c)
            when 18 =>
                poly_mul_mode <= "100";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "00";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- A * z - c * t1
            when 19 =>
                poly_mul_mode <= "110";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "00";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- INTT(A * z - c * t1)
            when 20 =>
                poly_mul_mode <= "101";
                poly_mul_next_bound_check_mode <= "10";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "00";
                repeats_target <= (0, param_k - 1);
                poly_mul_half <= '0';
                state_last <= '1';
            -- kyber - pke_key_gen, kem_key_gen
            -- NTT(s)
            when 21 =>
                poly_mul_mode <= "000";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "11";
                repeats_target <= (param_k - 1, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- NTT(e)
            when 22 =>
                poly_mul_mode <= "000";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "11";
                repeats_target <= (param_k - 1, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- A * s - first part
            when 23 =>
                poly_mul_mode <= "010";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "01";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- A * s - second part
            when 24 =>
                poly_mul_mode <= "011";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "11";
                repeats_target <= (0, param_k * param_k - 1);
                poly_mul_half <= '0';
                state_last <= '1';
            -- kyber - pke_dec, kem_dec
            -- NTT(u)
            when 25 =>
                poly_mul_mode <= "000";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "00";
                repeats_target <= (param_k - 1, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- s * u - first part
            when 26 =>
                poly_mul_mode <= "010";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "10";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- s * u -- second part
            when 27 =>
                poly_mul_mode <= "011";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "11";
                repeats_target <= (0, param_k - 1);
                poly_mul_half <= '0';
                state_last <= '0';
            -- INTT(s * u)
            when 28 =>
                poly_mul_mode <= "001";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "11";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= mode(2);
            -- kyber - pke_enc
            -- NTT(r)
            when 29 =>
                poly_mul_mode <= "000";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "11";
                repeats_target <= (param_k - 1, 0);
                poly_mul_half <= '1';
                state_last <= '0';
            -- A * r - first part
            when 30 =>
                poly_mul_mode <= "010";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "01";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- A * r - second part
            when 31 =>
                poly_mul_mode <= "011";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "11";
                repeats_target <= (0, param_k * param_k - 1);
                poly_mul_half <= '0';
                state_last <= '0';
            -- t * r - first part
            when 32 =>
                poly_mul_mode <= "010";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "01";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- t * r -- second part
            when 33 =>
                poly_mul_mode <= "011";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "11";
                repeats_target <= (0, param_k - 1);
                poly_mul_half <= '0';
                state_last <= '0';
            -- INTT(A * r)
            when 34 =>
                poly_mul_mode <= "001";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "11";
                repeats_target <= (param_k - 1, 0);
                poly_mul_half <= '0';
                state_last <= '0';
            -- INTT(t * r)
            when 35 =>
                poly_mul_mode <= "001";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '1';
                poly_mul_has_shares <= "11";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '1';
            when others =>
                poly_mul_mode <= "111";
                poly_mul_next_bound_check_mode <= "00";
                poly_mul_bram_mux <= '0';
                poly_mul_has_shares <= "00";
                repeats_target <= (0, 0);
                poly_mul_half <= '0';
                state_last <= '1';
        end case;
    end process;

    process(clk) is
    begin
        if rising_edge(clk) then
            if poly_mul_rdy = '1' then
                case state_in is
                    -- dilithium - key_gen
                    when 0 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 1 => poly_mul_coeffs_fifo_mode_in <= "000" when repeats_in(1) = 0 else "001";
                    when 2 => poly_mul_coeffs_fifo_mode_in <= "000";
                    -- dilithium - sign
                    when 3 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 4 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 5 => poly_mul_coeffs_fifo_mode_in <= "000" when repeats_in(1) = 0 else "001";
                    when 6 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 7 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 8 => poly_mul_coeffs_fifo_mode_in <= "001";
                    when 9 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 10 => poly_mul_coeffs_fifo_mode_in <= "010";
                    when 11 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 12 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 13 => poly_mul_coeffs_fifo_mode_in <= "000";
                    -- dilithium - verify
                    when 14 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 15 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 16 => poly_mul_coeffs_fifo_mode_in <= "000" when repeats_in(1) = 0 else "001";
                    when 17 => poly_mul_coeffs_fifo_mode_in <= "000" when repeats_in(1) = 0 else "001";
                    when 18 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 19 => poly_mul_coeffs_fifo_mode_in <= "010";
                    when 20 => poly_mul_coeffs_fifo_mode_in <= "000";
                    -- kyber - pke_key_gen, kem_key_gen
                    when 21 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 22 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 23 => poly_mul_coeffs_fifo_mode_in <= "001";
                    when 24 => poly_mul_coeffs_fifo_mode_in <= "011";
                    -- kyber - pke_dec
                    when 25 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 26 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 27 => poly_mul_coeffs_fifo_mode_in <= "100" when repeats_in(1) = 0 else "001" when repeats_in(1) = repeats_target(1) else "101";
                    when 28 => poly_mul_coeffs_fifo_mode_in <= "000";
                    -- kyber - pke_enc
                    when 29 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 30 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 31 => poly_mul_coeffs_fifo_mode_in <= "100" when repeats_in(1) mod param_k = 0 else "001" when repeats_in(1) mod param_k = param_k - 1 else "101";
                    when 32 => poly_mul_coeffs_fifo_mode_in <= "000";
                    when 33 => poly_mul_coeffs_fifo_mode_in <= "100" when repeats_in(1) = 0 else "001" when repeats_in(1) = repeats_target(1) else "101";
                    when others => poly_mul_coeffs_fifo_mode_in <= "000";
                end case;
            end if;

            if poly_mul_start = '1' then
                case state_in is
                    -- dilithium - key_gen
                    when 0 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(param_k + param_l + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(param_k + param_l + repeats_in(1), 6));
                    when 1 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(param_k + param_l + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * (param_k + param_l) + repeats_in(0), 6));
                    when 2 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * (param_k + param_l) + repeats_in(0), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * (param_k + param_l) + repeats_in(0), 6));
                    -- dilithium - sign
                    when 3 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(repeats_in(0), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(repeats_in(0), 6));
                    when 4 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * param_k + param_l + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * param_k + param_l + repeats_in(1), 6));
                    when 5 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * param_k + param_l + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * (param_k + param_l) + repeats_in(0), 6));
                    when 6 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(3 * param_k + 2 * param_l + repeats_in(0), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * (param_k + param_l) + repeats_in(0), 6));
                    when 7 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= "000000";
                        poly_mul_addrb_offset1 <= "000000";
                    when 8 =>
                        poly_mul_repeat_read <= '1';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * param_k + param_l + repeats_in(1), 6));
                    when 9 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * param_k + param_l + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * param_k + param_l + repeats_in(1), 6));
                    when 10 =>
                        poly_mul_repeat_read <= '1';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(param_l + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * (param_l + param_k) + repeats_in(1), 6));
                    when 11 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * (param_l + param_k) + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * (param_l + param_k) + repeats_in(1), 6));
                    when 12 =>
                        poly_mul_repeat_read <= '1' when repeats_in(1) /= param_k - 1 else '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(param_l + param_k + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= "000000";
                    when 13 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(3 * param_k + 2 * param_l + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(3 * param_k + 2 * param_l + repeats_in(1), 6));
                    -- dilithium - verify
                    when 14 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(repeats_in(0), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(repeats_in(0), 6));
                    when 15 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(param_k + repeats_in(0), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(param_k + repeats_in(0), 6));
                    when 16 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(param_k + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * (param_l + param_k), 6));
                    when 17 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(param_k + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * (param_l + param_k) + 1 + repeats_in(0), 6));
                    when 18 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= "000000";
                        poly_mul_addrb_offset1 <= "000000";
                    when 19 =>
                        poly_mul_repeat_read <= '1';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * (param_l + param_k) + repeats_in(1), 6));
                    when 20 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * (param_l + param_k) + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * (param_l + param_k) + repeats_in(1), 6));
                    -- kyber - pke_key_gen, kem_key_gen
                    when 21 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(repeats_in(0), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(repeats_in(0), 6));
                    when 22 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(param_k + repeats_in(0), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(param_k + repeats_in(0), 6));
                    when 23 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned((repeats_in(1) / param_k), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(param_k + (repeats_in(1) mod param_k), 6));
                    when 24 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * param_k + (repeats_in(1) mod param_k), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(3 * param_k + (repeats_in(1) mod param_k), 6));
                    -- kyber - pke_dec
                    when 25 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * param_k + repeats_in(0), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * param_k + repeats_in(0), 6));
                    when 26 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * param_k + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(repeats_in(1), 6));
                    when 27 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(5 * param_k, 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * param_k, 6));
                    when 28 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * param_k, 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * param_k, 6));
                    -- kyber - pke_enc
                    when 29 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * param_k + 1 + repeats_in(0), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * param_k + 1 + repeats_in(0), 6));
                    when 30 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * param_k + 1 + (repeats_in(1) mod param_k), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * param_k + 1 + (repeats_in(1) mod param_k), 6));
                    when 31 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(4 * param_k + 1 + (repeats_in(1) / param_k), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(5 * param_k + 1 + (repeats_in(1) / param_k), 6));
                    when 32 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * param_k + 1 + repeats_in(1), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(param_k + repeats_in(1), 6));
                    when 33 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * param_k + 1, 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(5 * param_k + 1, 6));
                    when 34 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(3 * param_k + 1 + (repeats_in(0)), 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(3 * param_k + 1 + (repeats_in(0)), 6));
                    when 35 =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= std_logic_vector(to_unsigned(2 * param_k + 1, 6));
                        poly_mul_addrb_offset1 <= std_logic_vector(to_unsigned(2 * param_k + 1, 6));
                    when others =>
                        poly_mul_repeat_read <= '0';
                        poly_mul_addrb_offset0 <= "000000";
                        poly_mul_addrb_offset1 <= "000000";
                end case;
            end if;

            if poly_mul_vld = '1' or (poly_mul_start_reg = '1' and started_count = 1) then
                poly_mul_coeffs_fifo_mode_out <= poly_mul_coeffs_fifo_mode_in;

                case state_out is
                    -- dilithium - key_gen
                    when 0 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(param_k + param_l + repeats_out(1), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    when 1 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(2 * (param_k + param_l) + repeats_out(0), 6));
                        poly_mul_offset_we <= "10";
                    when 2 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(2 * (param_k + param_l) + repeats_out(0), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    -- dilithium - sign
                    when 3 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(repeats_out(0), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    when 4 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(2 * param_k + param_l + repeats_out(1), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    when 5 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(2 * (param_k + param_l) + repeats_out(0), 6));
                        poly_mul_offset_we <= "10";
                    when 6 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(3 * param_k + 2 * param_l + repeats_out(0), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    when 7 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '1';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "00";
                    when 8 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(2 * param_k + param_l + repeats_out(1), 6));
                        poly_mul_offset_we <= "10";
                    when 9 =>
                        poly_mul_bound_check_mode <= "01";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(2 * param_k + param_l + repeats_out(1), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    when 10 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(2 * (param_l + param_k) + repeats_out(1), 6));
                        poly_mul_offset_we <= "10";
                    when 11 =>
                        poly_mul_bound_check_mode <= "10";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(2 * (param_l + param_k) + repeats_out(1), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    when 12 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(3 * param_k + 2 * param_l + repeats_out(1), 6));
                        poly_mul_offset_we <= "10";
                    when 13 =>
                        poly_mul_bound_check_mode <= "11";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(3 * param_k + 2 * param_l + repeats_out(1), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    -- dilithium - verify
                    when 14 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(repeats_out(0), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    when 15 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(param_k + repeats_out(0), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    when 16 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(2 * (param_k + param_l), 6));
                        poly_mul_offset_we <= "10";
                    when 17 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(2 * (param_k + param_l) + 1 + repeats_out(0), 6));
                        poly_mul_offset_we <= "10";
                    when 18 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '1';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "00";
                    when 19 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(2 * (param_l + param_k) + repeats_out(1), 6));
                        poly_mul_offset_we <= "10";
                    when 20 =>
                        poly_mul_bound_check_mode <= "10";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(2 * (param_l + param_k) + repeats_out(1), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    -- kyber - pke_key_gen, kem_key_gen
                    when 21 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(repeats_out(0), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    when 22 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(param_k + repeats_out(0), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    when 23 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(2 * param_k + (repeats_out(1) mod param_k), 6));
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(3 * param_k + (repeats_out(1) mod param_k), 6));
                        poly_mul_offset_we <= "11";
                    when 24 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(param_k + (repeats_out(1) mod param_k), 6));
                        poly_mul_offset_we <= "10";
                    -- kyber - pke_dec
                    when 25 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(2 * param_k + repeats_out(0), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "11";
                    when 26 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(5 * param_k, 6));
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(2 * param_k, 6));
                        poly_mul_offset_we <= "11";
                    when 27 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(2 * param_k, 6));
                        poly_mul_offset_we <= "10";
                    when 28 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(2 * param_k, 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    -- kyber - pke_enc
                    when 29 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(2 * param_k + 1 + repeats_out(0), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    when 30 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(4 * param_k + 1 + (repeats_out(1) / param_k), 6));
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(5 * param_k + 1 + (repeats_out(1) / param_k), 6));
                        poly_mul_offset_we <= "11";
                    when 31 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(3 * param_k + 1 + (repeats_out(1) / param_k), 6));
                        poly_mul_offset_we <= "10";
                    when 32 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(2 * param_k + 1, 6));
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(5 * param_k + 1, 6));
                        poly_mul_offset_we <= "11";
                    when 33 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= std_logic_vector(to_unsigned(2 * param_k + 1, 6));
                        poly_mul_offset_we <= "10";
                    when 34 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(3 * param_k + 1 + repeats_out(0), 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    when 35 =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= std_logic_vector(to_unsigned(2 * param_k + 1, 6));
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "01";
                    when others =>
                        poly_mul_bound_check_mode <= "00";
                        poly_mul_first_bram_only <= '0';
                        poly_mul_addra_offset0 <= "000000";
                        poly_mul_addra_offset1 <= "000000";
                        poly_mul_offset_we <= "00";
                end case;
            end if;

            if (rst or sig_invalid) = '1' then
                poly_mul_half_finished <= '0';
                poly_mul_finished <= '0';
            else
                if poly_mul_vld = '1' or (poly_mul_start_reg = '1' and started_count = 1) then
                    case state_out is
                        -- dilithium - key_gen
                        when 0 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 1 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 2 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        -- dilithium - sign
                        when 3 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 4 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 5 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 6 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 7 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 8 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 9 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 10 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 11 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 12 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 13 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        -- dilithium - verify
                        when 14 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 15 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 16 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 17 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 18 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 19 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 20 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        -- kyber - pke_key_gen, kem_key_gen
                        when 21 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 22 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 23 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 24 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        -- kyber - pke_dec
                        when 25 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 26 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 27 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 28 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        -- kyber - pke_enc
                        when 29 =>
                            poly_mul_half_finished <= '1';
                            poly_mul_finished <= '0';
                        when 30 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 31 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 32 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 33 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 34 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when 35 =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '0';
                        when others =>
                            poly_mul_half_finished <= '0';
                            poly_mul_finished <= '1';
                    end case;
                end if;
            end if;
        end if;
    end process;

    proc_state: process(clk) is
    begin
        if rising_edge(clk) then
            poly_mul_start_reg <= poly_mul_start;

            if rst = '1' then
                state_in <= initial_state;
                state_out <= initial_state;

                poly_mul_running <= '0';
                started_count <= 0;

                repeats_in <= (0, 0);
                repeats_out <= (0, 0);
            else
                if poly_mul_start = '1' then
                    poly_mul_running <= '1';

                    for i in 0 to 1 loop
                        if repeats_in(i) = repeats_target(i) then
                            repeats_in(i) <= 0;
                        elsif repeats_target(i) /= 0 then
                            repeats_in(i) <= repeats_in(i) + 1;
                            exit;
                        end if;
                    end loop;

                    if repeats_in(0) = repeats_target(0) then
                        if repeats_target(1) = 0 or repeats_in(1) = repeats_target(1) then
                            if state_last = '1' then
                                state_in <= 1000;
                            else
                                state_in <= state_in + 1;
                            end if;
                        else
                            state_in <= state_in - 1;
                        end if;
                    end if;
                end if;

                if poly_mul_vld = '1' or (poly_mul_start_reg = '1' and started_count = 1) then
                    state_out <= state_in;
                    repeats_out <= repeats_in;
                end if;

                if (poly_mul_start and not poly_mul_vld) = '1' then
                    started_count <= started_count + 1;
                elsif (poly_mul_vld and not poly_mul_start) = '1' then
                    if started_count = 1 then
                        poly_mul_running <= '0';
                    end if;

                    started_count <= started_count - 1;
                end if;

                if sig_invalid = '1' then
                    state_in <= 4;
                    state_out <= 4;

                    started_count <= 0;

                    repeats_in <= (0, 0);
                    repeats_out <= (0, 0);
                end if;
            end if;
        end if;
    end process;
end;
