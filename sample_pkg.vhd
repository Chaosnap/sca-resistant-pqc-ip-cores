-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;
use work.types_pkg.all;

package sample_pkg is
    -- rejection of 2 (4) coefficients for dilithium (kyber) matrix A expansion
    function rej_ntt(bytes: std_logic_vector(47 downto 0); mode: std_logic) return std_logic_vector;

    -- make sure rejected coefficients are valid from LSB
    procedure reorder_rej_ntt(signal coeffs: in std_logic_vector(47 downto 0); signal coeffs_vld: in std_logic_vector(3 downto 0); signal coeffs_reordered: out std_logic_vector(47 downto 0); signal coeffs_reordered_count_vld: out natural range 0 to 4);
end;

package body sample_pkg is
    function rej_ntt(bytes: std_logic_vector(47 downto 0); mode: std_logic) return std_logic_vector is
        variable q: signed(25 downto 0);
        variable sum: signed(25 downto 0);

        variable coeffs_vld: std_logic_vector(3 downto 0);
    begin
        if mode = '1' then
            q := '0' & signed(DILITHIUM_Q(23 downto 12)) & '0' & signed(DILITHIUM_Q(11 downto 0));
        else
            q := '0' & signed(KYBER_Q) & '0' & signed(KYBER_Q);
        end if;

        for i in 0 to 1 loop
            sum := '0' & (bytes(23 + 24 * i) and (not mode)) & signed(bytes(22 + 24 * i downto 12 + 24 * i)) & not mode & signed(bytes(11 + 24 * i downto 24 * i)) - q;

            coeffs_vld(2 * i) := ((not sum(12)) and (not mode)) or (mode and sum(25));
            coeffs_vld(1 + 2 * i) := sum(25);
        end loop;

        return coeffs_vld;
    end function;

    procedure reorder_rej_ntt(signal coeffs: in std_logic_vector(47 downto 0); signal coeffs_vld: in std_logic_vector(3 downto 0); signal coeffs_reordered: out std_logic_vector(47 downto 0); signal coeffs_reordered_count_vld: out natural range 0 to 4) is
    begin
        case coeffs_vld is
            when "0010" => coeffs_reordered <= coeffs(47 downto 12) & coeffs(23 downto 12);
            when "0100" => coeffs_reordered <= coeffs(47 downto 12) & coeffs(35 downto 24);
            when "0101" => coeffs_reordered <= coeffs(47 downto 24) & coeffs(35 downto 24) & coeffs(11 downto 0);
            when "0110" => coeffs_reordered <= coeffs(47 downto 24) & coeffs(35 downto 12);
            when "1000" => coeffs_reordered <= coeffs(47 downto 12) & coeffs(47 downto 36);
            when "1001" => coeffs_reordered <= coeffs(47 downto 24) & coeffs(47 downto 36) & coeffs(11 downto 0);
            when "1010" => coeffs_reordered <= coeffs(47 downto 24) & coeffs(47 downto 36) & coeffs(23 downto 12);
            when "1011" => coeffs_reordered <= coeffs(47 downto 36) & coeffs(47 downto 36) & coeffs(23 downto 0);
            when "1100" => coeffs_reordered <= coeffs(47 downto 24) & coeffs(47 downto 24);
            when "1101" => coeffs_reordered <= coeffs(47 downto 36) & coeffs(47 downto 24) & coeffs(11 downto 0);
            when "1110" => coeffs_reordered <= coeffs(47 downto 36) & coeffs(47 downto 12);
            when others => coeffs_reordered <= coeffs;
        end case;

        case coeffs_vld is
            when "0001" | "0010" | "0100" | "1000" => coeffs_reordered_count_vld <= 1;
            when "0011" | "0101" | "0110" | "1001" | "1010" | "1100" => coeffs_reordered_count_vld <= 2;
            when "0111" | "1011" | "1101" | "1110" => coeffs_reordered_count_vld <= 3;
            when "1111" => coeffs_reordered_count_vld <= 4;
            when others => coeffs_reordered_count_vld <= 0;
        end case;
    end procedure;
end;
