-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;

-- determines current mode of `bram1` component
entity bram1_state_machine is
port (
    clk: in std_logic;
    rst: in std_logic;

    mode: in std_logic_vector(10 downto 0);

    param_k: in natural range 2 to 8;
    param_l: in natural range 4 to 7;

    next_mode: in std_logic;

    -- indicates what should be outputed from `bram1`
    -- dilithium - key_gen
    -- 0000 - t for power2round
    -- 0001 - s1/s2 (not really from `bram1` right now)
    -- 0010 - t0
    -- dilithium - sign
    -- 0011 - w for high bits
    -- 0100 - ct0 when computing w - cs2 - ct0
    -- 0101 - w - cs2 for low bits
    -- 0110 - z
    -- dilithium - verify
    -- 0111 - w for high bits
    -- kyber - pke_key_gen, kem_key_gen
    -- 1000 - t
    -- 1001 - s
    -- kyber - pke_dec, kem_dec
    -- 1010 - w
    -- kyber - pke_enc, kem_enc, kem_dec (continues)
    -- 1011 - u
    -- 1100 - v
    -- 1101 - m
    bram1_mode: out std_logic_vector(3 downto 0);

    bram1_addrb_offset: out std_logic_vector(5 downto 0)
);
end;

architecture behav of bram1_state_machine is
    type repeats_t is array(integer range <>) of natural range 0 to 23;

    -- holds info about how many times this sequence was already repeated
    -- it is indexed by `repeat_index_offset` as this should be always unique for given sequence
    signal repeats: repeats_t(0 to 1);
    signal repeats_target: repeats_t(0 to 1);

    subtype state_t is natural range 0 to 20;
    signal state, initial_state: state_t;

    signal state_last: std_logic;
begin
    with mode(8 downto 0) select initial_state <=
        0 when "001000000", -- dilithium - key_gen
        3 when "010000000", -- dilithium - sign
        7 when "100000000", -- dilithium - verify
        8 when "000000001" | "000001000", -- kyber - pke_key_gen, kem_key_gen
        11 when "000000100" | "000100000", -- kyber - pke_dec, kem_dec
        12 when "000000010" | "000010000", -- kyber - pke_enc, kem_enc
        20 when others;

    process(all) is
    begin
        case state is
            -- dilithium - key_gen
            when 0 =>
                repeats_target <= (param_k - 1, 0);
                state_last <= '0';
            when 1 =>
                repeats_target <= (param_k + param_l - 1, 0);
                state_last <= '0';
            when 2 =>
                repeats_target <= (param_k - 1, 0);
                state_last <= '1';
            -- dilithium - sign
            when 3 =>
                repeats_target <= (param_k - 1, 0);
                state_last <= '0';
            when 4 =>
                repeats_target <= (0, 0);
                state_last <= '0';
            when 5 =>
                repeats_target <= (0, param_k - 1);
                state_last <= '0';
            when 6 =>
                repeats_target <= (param_k - 1, 0);
                state_last <= '1';
            -- dilithium - verify
            when 7 =>
                repeats_target <= (param_k - 1, 0);
                state_last <= '1';
            -- kyber - pke_key_gen, kem_key_gen
            when 8 =>
                repeats_target <= (param_k - 1, 0);
                state_last <= '0';
            when 9 =>
                repeats_target <= (param_k - 1, 0);
                state_last <= mode(0);
            -- only kem_key_gen continues
            when 10 =>
                repeats_target <= (param_k - 1, 0);
                state_last <= '1';
            -- kyber - pke_dec, kem_dec
            when 11 =>
                repeats_target <= (0, 0);
                state_last <= mode(2);
            -- kyber - pke_enc, kem_enc, kem_dec (continues)
            when 12 =>
                repeats_target <= (param_k - 1, 0);
                state_last <= '0';
            when 13 =>
                repeats_target <= (0, 0);
                state_last <= '0';
            when 14 =>
                repeats_target <= (0, 0);
                state_last <= '1';
            when others =>
                repeats_target <= (0, 0);
                state_last <= '1';
        end case;
    end process;

    process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                bram1_mode <= "1111";
                bram1_addrb_offset <= (others => '0');
            else
                case state is
                    -- dilithium - key_gen
                    when 0 =>
                        bram1_mode <= "0000";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(2 * (param_k + param_l) + repeats(0), 6));
                    when 1 =>
                        bram1_mode <= "0001";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(repeats(0), 6));
                    when 2 =>
                        bram1_mode <= "0010";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(param_k + param_l + repeats(0), 6));
                    -- dilithium - sign
                    when 3 =>
                        bram1_mode <= "0011";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(3 * param_k + 2 * param_l + repeats(0), 6));
                    when 4 =>
                        bram1_mode <= "0101";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(2 * (param_k + param_l) + repeats(1), 6));
                    when 5 =>
                        bram1_mode <= "0100";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(3 * param_k + 2 * param_l + repeats(1), 6));
                    when 6 =>
                        bram1_mode <= "0110";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(2 * param_k + param_l + repeats(0), 6));
                    -- dilithium - verify
                    when 7 =>
                        bram1_mode <= "0111";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(2 * (param_k + param_l) + repeats(0), 6));
                    -- kyber - pke_key_gen, kem_key_gen
                    when 8 =>
                        bram1_mode <= "1000";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(param_k + repeats(0), 6));
                    when 9 =>
                        bram1_mode <= "1001";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(repeats(0), 6));
                    -- only kem_key_gen continues
                    when 10 =>
                        bram1_mode <= "1000";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(param_k + repeats(0), 6));
                    -- kyber - pke_dec, kem_dec
                    when 11 =>
                        bram1_mode <= "1010";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(2 * param_k, 6));
                    -- kyber - pke_enc, kem_enc, kem_dec (continues)
                    when 12 =>
                        bram1_mode <= "1011";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(3 * param_k + 1 + repeats(0), 6));
                    when 13 =>
                        bram1_mode <= "1100";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(2 * param_k + 1, 6));
                    when 14 =>
                        bram1_mode <= "1101";
                        bram1_addrb_offset <= std_logic_vector(to_unsigned(2 * param_k, 6));
                    when others =>
                        bram1_mode <= "1111";
                        bram1_addrb_offset <= (others => '0');
                end case;
            end if;
        end if;
    end process;

    proc_state: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= initial_state;
                repeats <= (0, 0);
            else
                if next_mode = '1' then
                    for i in 0 to 1 loop
                        if repeats(i) = repeats_target(i) then
                            repeats(i) <= 0;
                        elsif repeats_target(i) /= 0 then
                            repeats(i) <= repeats(i) + 1;
                            exit;
                        end if;
                    end loop;

                    if repeats(0) = repeats_target(0) then
                        if repeats_target(1) = 0 or repeats(1) = repeats_target(1) then
                            if state_last = '1' then
                                state <= 20;
                            else
                                state <= state + 1;
                            end if;
                        else
                            state <= state - 1;
                        end if;
                    end if;
                end if;
            end if;
        end if;
    end process;
end;
