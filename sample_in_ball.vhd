-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- samples coefficients from bytes
entity sample_in_ball is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- indicates dilithium's security level
    -- 00 - 2
    -- 01 - 3
    -- 10 - 5
    mode: in std_logic_vector(1 downto 0);

    -- data from keccak that should be used during sampling
    data_in: in std_logic_vector(7 downto 0);
    data_in_vld: in std_logic;

    -- sample coefficients
    m_axis_tdata: out std_logic_vector(95 downto 0);
    m_axis_tvalid: out std_logic;
    m_axis_tready: in std_logic
);
end;

architecture behav of sample_in_ball is
    -- TODO: load signs straight to memory
    -- store first 8 bytes for signs
    signal signs: std_logic_vector(63 downto 0);
    signal signs_vld: std_logic_vector(7 downto 0);

    -- small memory using LUTRAM to store sampled coefficients
    type coeffs_t is array(integer range <>) of std_logic_vector(7 downto 0);
    signal coeffs_i, coeffs_j: coeffs_t(63 downto 0) := (others => (others => '0'));

    -- signals for reading out coefficients
    signal coeffs_addr: unsigned(5 downto 0);
    signal output_coeffs: std_logic;

    -- indicates that input index is lower or equal to `index`
    signal coeff_vld: std_logic;

    signal index, initial_index: natural range 196 to 255;
    signal index_last: std_logic;
begin
    gen_out: for i in 0 to 3 generate
        m_axis_tdata(23 + 24 * i downto 24 * i) <= x"000001" when coeffs_j(to_integer(coeffs_addr))(1 + 2 * i downto 2 * i) = "01" else
            x"7fe000" when coeffs_j(to_integer(coeffs_addr))(1 + 2 * i downto 2 * i) = "10" else
            x"000001" when coeffs_i(to_integer(coeffs_addr))(1 + 2 * i downto 2 * i) = "01" else
            x"7fe000" when coeffs_i(to_integer(coeffs_addr))(1 + 2 * i downto 2 * i) = "10" else
            (others => '0');
    end generate;

    m_axis_tvalid <= output_coeffs;

    -- load signs from first 8 bytes
    proc_signs: process(clk) is
    begin
        if rising_edge(clk) then
            if (data_in_vld and not signs_vld(0)) = '1' then
                signs <= data_in & signs(63 downto 8);
            end if;

            if (rst or (output_coeffs and (and coeffs_addr) and m_axis_tready)) = '1' then
                signs_vld <= (others => '0');
            else
                if data_in_vld = '1' then
                    signs_vld <= '1' & signs_vld(7 downto 1);
                end if;
            end if;
        end if;
    end process;

    coeff_vld <= data_in_vld when unsigned(data_in) <= index else '0';

    with mode select initial_index <=
        217 when "00",
        207 when "01",
        196 when others;

    index_last <= '1' when index = 255 else '0';

    proc_coeffs: process(clk) is
        variable coeffs: std_logic_vector(7 downto 0);
        variable j: natural range 0 to 255;
    begin
        if rising_edge(clk) then
            if or (not signs_vld) = '1' then
                index <= initial_index;
            else
                if (coeff_vld and not index_last) = '1' then
                    index <= index + 1;
                end if;

                if (coeff_vld and not output_coeffs) = '1' then
                    coeffs := coeffs_i(index / 4);
                    j := to_integer(unsigned(data_in));

                    coeffs(1 + 2 * (index mod 4) downto 2 * (index mod 4)) := coeffs_j(j / 4)(1 + 2 * (j mod 4) downto 2 * (j mod 4));

                    if coeffs(1 + 2 * (index mod 4) downto 2 * (index mod 4)) = "00" then
                        coeffs(1 + 2 * (index mod 4) downto 2 * (index mod 4)) := coeffs_i(j / 4)(1 + 2 * (j mod 4) downto 2 * (j mod 4));
                    end if;

                    coeffs_i(index / 4) <= coeffs;

                    coeffs := coeffs_j(j / 4);

                    coeffs(1 + 2 * (j mod 4) downto 2 * (j mod 4)) := "01" when signs(index - initial_index) = '0' else "10";
                    coeffs_j(j / 4) <= coeffs;
                elsif (output_coeffs and m_axis_tready) = '1' then
                    coeffs_i(to_integer(coeffs_addr)) <= x"00";
                    coeffs_j(to_integer(coeffs_addr)) <= x"00";
                end if;
            end if;
        end if;
    end process;

    proc_out: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                output_coeffs <= '0';

                coeffs_addr <= (others => '0');
            else
                if (coeff_vld and index_last) = '1' then
                    output_coeffs <= '1';
                elsif ((and coeffs_addr) and m_axis_tready) = '1' then
                    output_coeffs <= '0';
                end if;

                if (output_coeffs and m_axis_tready) = '1' then
                    coeffs_addr <= coeffs_addr + 1;
                end if;
            end if;
        end if;
    end process;
end;