-- Copyright (C) 2025 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;
use work.reduce_pkg.all;
use work.types_pkg.all;

-- secure implementation of sampling in bound for Dilithium
-- sampling for ETA=2 does not follow FIPS 204, but https://eprint.iacr.org/2022/1406.pdf as there is no available algorithm for masked sampling as proposed by FIPS 204
entity sec_sample_bounded is
port (
    clk: in std_logic;
    rst: in std_logic;

    random: in std_logic_vector(24 downto 0);

    -- 0 - sample bounded ETA=2 - input shake-256
    -- 1 - sample bounded ETA=4 - input shake-256
    -- must be valid during whole computation
    mode: in std_logic;

    s_axis_tdata: in slv_array_t(1 downto 0)(15 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    coeffs: out slv_array_t(1 downto 0)(15 downto 0);
    coeffs_vld: out std_logic
);
end;

architecture behav of sec_sample_bounded is
    constant SEC_ADD_DELAY: natural := 7;

    -- sec boolean addition signals
    signal sec_add_x, sec_add_y: slv_array_t(1 downto 0)(4 downto 0);
    signal sec_add_r: slv_array_t(4 downto 0)(4 downto 0);
    signal sec_add_z: slv_array_t(1 downto 0)(4 downto 0);
    signal sec_add_vld_in, sec_add_vld_out: std_logic;

    signal sec_add_z_r: std_logic_vector(1 downto 0);
    signal sec_add_vld_out_r: std_logic;

    -- 4b are used per cycle => 4 transactions
    signal data_count: natural range 0 to 3;
    signal data_count_last: std_logic;

    -- data will be needed when the bound is checked, so it is delayed using shift register
    -- 4b shares are combined => 8b width
    signal data_shift_reg: slv_array_t(SEC_ADD_DELAY - 1 downto 0)(7 downto 0);

    -- indicates coefficient is in bound
    signal sampled_vld: std_logic;

    -- `sec_add` processes only 1 coefficient at time, so it needs to be merged back to 4
    signal sampled_count: natural range 0 to 3;
    signal sampled_count_last: std_logic;

    -- after sampling coefficients need to be adjusted to correct range
    signal coeffs_r: slv_array_t(1 downto 0)(15 downto 0);
    signal coeffs_vld_r: std_logic;

    -- assigning DON'T TOUCH attribute
    attribute dont_touch: string;
    attribute dont_touch of behav: architecture is "yes";

    attribute dont_touch of sec_add_x, sec_add_y: signal is "yes";
begin
    s_axis_tready <= (sec_add_vld_in and data_count_last);

    coeffs <= coeffs_r;
    coeffs_vld <= coeffs_vld_r;

    -- Secure addition of boolean shares

    sec_add: entity work.sec_add
    generic map (
        W => 5
    )
    port map (
        clk => clk,
        rst => rst,

        x => sec_add_x,
        y => sec_add_y,
        vld_in => sec_add_vld_in,

        r => sec_add_r,

        z => sec_add_z,
        vld_out => sec_add_vld_out
    );

    sec_add_random_g: for i in 0 to 4 generate
        sec_add_r(i) <= random(4 + 5 * i downto 5 * i);
    end generate;

    -- `sec_add` assignments
    sec_add_g: for i in 0 to 1 generate
        sec_add_x(i)(4 downto 0) <= '0' & s_axis_tdata(i)(3 + 4 * data_count downto 4 * data_count);
    end generate;

    -- subtract 5 or 9, depending on the mode, to check the bound
    sec_add_y(0) <= '1' & x"b" when mode = '0' else '1' & x"7";
    sec_add_y(1) <= (others => '0');

    sec_add_vld_in <= s_axis_tvalid;

    -- delay data that are being bound checked
    data_shift_reg_p: process(clk) is
    begin
        if rising_edge(clk) then
            data_shift_reg(data_shift_reg'left) <= (sec_add_x(1)(3 downto 0) & sec_add_x(0)(3 downto 0));
            data_shift_reg(data_shift_reg'left - 1 downto 0) <= data_shift_reg(data_shift_reg'left downto 1);
        end if;
    end process;

    data_count_last <= '1' when data_count = 3 else '0';

    -- count read data words (4b)
    data_count_p: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                data_count <= 0;
            else
                if sec_add_vld_in = '1' then
                    if data_count_last = '1' then
                        data_count <= 0;
                    else
                        data_count <= data_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    -- choose which coefficients should be outputed
    coeffs_p: process(clk) is
    begin
        if rising_edge(clk) then
            for i in 0 to 1 loop
                coeffs_r(i)(3 + 4 * sampled_count downto 4 * sampled_count) <= data_shift_reg(0)(3 + 4 * i downto 4 * i);
            end loop;

            if rst = '1' then
                coeffs_vld_r <= '0';
            else
                coeffs_vld_r <= sampled_vld and sampled_count_last;
            end if;
        end if;
    end process;

    -- register before unmasking
    sampled_vld_p: process(clk) is
    begin
        if rising_edge(clk) then
            if sec_add_vld_out = '1' then
                sec_add_z_r(0) <= sec_add_z(0)(4);
                sec_add_z_r(1) <= sec_add_z(1)(4);
            end if;

            if rst = '1' then
                sec_add_vld_out_r <= '0';
            else
                sec_add_vld_out_r <= sec_add_vld_out;
            end if;
        end if;
    end process;

    -- if result of subtracting high bound is negative then the coeff is in bound
    sampled_vld <= sec_add_vld_out_r and (sec_add_z_r(0) xor sec_add_z_r(1));

    sampled_count_last <= '1' when sampled_count = 3 else '0';

    -- count sampled coefficients for merging to packs of 4
    sampled_count_p: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                sampled_count <= 0;
            else
                if sampled_vld = '1' then
                    if sampled_count_last = '1' then
                        sampled_count <= 0;
                    else
                        sampled_count <= sampled_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;
end;
