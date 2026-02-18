-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;

package reduce_pkg is
    -- output is valid with delay of 3 cycles
    constant BARRETT_REDUCE_DELAY: natural := 3;

    -- compute (x + y) % q for kyber
    function kyber_add_reduce(x: std_logic_vector(11 downto 0); y: std_logic_vector(11 downto 0)) return std_logic_vector;

    -- compute (x - y) % q for kyber
    function kyber_sub_reduce(x: std_logic_vector(11 downto 0); y: std_logic_vector(11 downto 0)) return std_logic_vector;

    -- compute (x + y) % q for dilithium
    function dilithium_add_reduce(x: std_logic_vector(23 downto 0); y: std_logic_vector(23 downto 0)) return std_logic_vector;

    -- compute (x - y) % q for dilithium
    function dilithium_sub_reduce(x: std_logic_vector(23 downto 0); y: std_logic_vector(23 downto 0)) return std_logic_vector;

    -- compute (x + y) % q for dilithium (mode = '0') or ((x(23 downto 12) + y(23 downto 12)) % q(23 downto 12) & (x(11 downto 0) + y(11 downto 0)) % q(11 downto 0)) for kyber (mode = '1')
    function add_reduce(x: std_logic_vector(23 downto 0); y: std_logic_vector(23 downto 0); mode: std_logic) return std_logic_vector;

    -- compute (x - y) % q for dilithium (mode = '0') or ((x(23 downto 12) - y(23 downto 12)) % q(23 downto 12) & (x(11 downto 0) - y(11 downto 0)) % q(11 downto 0)) for kyber (mode = '1')
    function sub_reduce(x: std_logic_vector(23 downto 0); y: std_logic_vector(23 downto 0); mode: std_logic) return std_logic_vector;
end;

package body reduce_pkg is
    function kyber_add_reduce(x: std_logic_vector(11 downto 0); y: std_logic_vector(11 downto 0)) return std_logic_vector is
        variable xy: std_logic_vector(11 downto 0);
        variable xyq: std_logic_vector(12 downto 0);
    begin
        xy := std_logic_vector(unsigned(x) + unsigned(y));
        xyq := std_logic_vector(signed('0' & x) + signed('0' & y) - signed('0' & KYBER_Q));

        if xyq(12) = '1' then
            return xy;
        else
            return xyq(11 downto 0);
        end if;
    end function;

    function kyber_sub_reduce(x: std_logic_vector(11 downto 0); y: std_logic_vector(11 downto 0)) return std_logic_vector is
        variable xy: std_logic_vector(12 downto 0);
        variable xyq: std_logic_vector(12 downto 0);
    begin
        xy := std_logic_vector(signed('0' & x) - signed('0' & y));
        xyq := std_logic_vector(signed(xy) + signed('0' & KYBER_Q));

        if xy(12) = '0' then
            return xy(11 downto 0);
        else
            return xyq(11 downto 0);
        end if;
    end function;

    function dilithium_add_reduce(x: std_logic_vector(23 downto 0); y: std_logic_vector(23 downto 0)) return std_logic_vector is
        variable xy: std_logic_vector(23 downto 0);
        variable xyq: std_logic_vector(24 downto 0);
    begin
        xy := std_logic_vector(unsigned(x) + unsigned(y));
        xyq := std_logic_vector(signed('0' & x) + signed('0' & y) - signed('0' & DILITHIUM_Q));

        if xyq(24) = '1' then
            return xy;
        else
            return xyq(23 downto 0);
        end if;
    end function;

    function dilithium_sub_reduce(x: std_logic_vector(23 downto 0); y: std_logic_vector(23 downto 0)) return std_logic_vector is
        variable xy: std_logic_vector(23 downto 0);
        variable xyq: std_logic_vector(24 downto 0);
    begin
        xy := std_logic_vector(signed(x) - signed(y));
        xyq := std_logic_vector(signed('0' & x) - signed('0' & y) + signed('0' & DILITHIUM_Q));

        if xy(23) = '0' then
            return xy;
        else
            return xyq(23 downto 0);
        end if;
    end function;

    -- implementation based on this paper https://ieeexplore.ieee.org/stamp/stamp.jsp?tp=&arnumber=10483343
    function add_reduce(x: std_logic_vector(23 downto 0); y: std_logic_vector(23 downto 0); mode: std_logic) return std_logic_vector is
        variable q: std_logic_vector(27 downto 0);

        variable sum: std_logic_vector(25 downto 0);
        variable sum_q: std_logic_vector(27 downto 0);
    begin
        if mode = '1' then
            q := "00" & DILITHIUM_Q(23 downto 12) & "00" & DILITHIUM_Q(11 downto 0);
        else
            q := "00" & KYBER_Q(11 downto 0) & "00" & KYBER_Q(11 downto 0);
        end if;

        sum := std_logic_vector(signed('0' & x(23 downto 12) & mode & x(11 downto 0)) + signed('0' & y(23 downto 12) & '0' & y(11 downto 0)));
        sum_q := std_logic_vector(signed('0' & sum(25 downto 13) & not mode & (not mode and sum(12)) & sum(11 downto 0)) - signed(q));

        if mode = '1' then
            if sum_q(27) = '1' then
                return sum(24 downto 13) & sum(11 downto 0);
            else
                return sum_q(25 downto 14) & sum_q(11 downto 0);
            end if;
        else
            if sum_q(27) = '1' and sum_q(12) = '1' then
                return sum(24 downto 13) & sum(11 downto 0);
            elsif sum_q(27) = '1' then
                return sum(24 downto 13) & sum_q(11 downto 0);
            elsif sum_q(12) = '1' then
                return sum_q(25 downto 14) & sum(11 downto 0);
            else
                return sum_q(25 downto 14) & sum_q(11 downto 0);
            end if;
        end if;
    end function;

    -- implementation based on this paper https://ieeexplore.ieee.org/stamp/stamp.jsp?tp=&arnumber=10483343
    function sub_reduce(x: std_logic_vector(23 downto 0); y: std_logic_vector(23 downto 0); mode: std_logic) return std_logic_vector is
        variable q: std_logic_vector(26 downto 0);

        variable sum: std_logic_vector(25 downto 0);
        variable sum_q: std_logic_vector(26 downto 0);
    begin
        if mode = '1' then
            q := '0' & DILITHIUM_Q(23 downto 12) & "00" & DILITHIUM_Q(11 downto 0);
        else
            q := '0' & KYBER_Q(11 downto 0) & "00" & KYBER_Q(11 downto 0);
        end if;

        sum := std_logic_vector(signed('0' & x(23 downto 12) & not mode & x(11 downto 0)) - signed('0' & y(23 downto 12) & '0' & y(11 downto 0)));
        sum_q := std_logic_vector(unsigned(sum(25 downto 13) & mode & (mode or sum(12)) & sum(11 downto 0)) + unsigned(q));

        if mode = '1' then
            if sum(25) = '0' then
                return sum(24 downto 13) & sum(11 downto 0);
            else
                return sum_q(25 downto 14) & sum_q(11 downto 0);
            end if;
        else
            if sum(25) = '0' and sum(12) = '1' then
                return sum(24 downto 13) & sum(11 downto 0);
            elsif sum(25) = '0' then
                return sum(24 downto 13) & sum_q(11 downto 0);
            elsif sum(12) = '1' then
                return sum_q(25 downto 14) & sum(11 downto 0);
            else
                return sum_q(25 downto 14) & sum_q(11 downto 0);
            end if;
        end if;
    end function;
end;
