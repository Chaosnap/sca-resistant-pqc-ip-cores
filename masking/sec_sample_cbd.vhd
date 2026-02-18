-- Copyright (C) 2025 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;
use work.types_pkg.all;

entity sec_sample_cbd is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- fresh randomness
    random: in std_logic_vector(17 downto 0);

    -- cbd2 -> 31 downto 0, cbd3 -> 47 downto 0
    s_axis_tdata: in slv_array_t(1 downto 0)(47 downto 0);
    s_axis_tvalid: in std_logic;
    s_axis_tready: out std_logic;

    -- outputs values with additional +3, (<1, 5> for cbd2 and <0, 6> for cbd3)
    coeffs: out slv_array_t(1 downto 0)(23 downto 0);
    coeffs_vld: out std_logic
);
end;

architecture behav of sec_sample_cbd is
    signal sec_and_x, sec_and_y: slv_array_t(1 downto 0)(17 downto 0);
    signal sec_and_r: slv_array_t(0 downto 0)(17 downto 0);
    signal sec_and_z: slv_array_t(1 downto 0)(17 downto 0);

    -- 4b/6b are used per cycle => 4 transactions
    signal data_count: natural range 0 to 3;
    signal data_count_last: std_logic;

    signal coeffs_r: slv_array_t(1 downto 0)(23 downto 0);
    signal coeffs_vld_r: std_logic;

    signal coeffs_count: natural range 0 to 3;
    signal coeffs_count_last: std_logic;

    -- description is for cbd3, corresponding operations happen in same stages for cbd2, with different number of bits
    -- first stage computes s1[0] = b[0] ^ b[1] ^ b[2], c1[0] = (b[0] & b[1]) ^ (b[0] & b[2]) ^ (b[1] ^ b[2]) and similar for s1'[0], c1'[0] with corresponding bits
    -- second stage computes s2[0] = s1[0] ^ ~s1'[0], c2[0] = s1[0] & ~s1'[0], s2[1] = c1[0] ^ ~c1'[0], c2[1] = c1[0] & ~c1'[0]
    -- third stage computes s3[0] = s2[0], s3[1] = s2[1] ^ c2[0], s3[2] = c2[1], c3[0] = s2[1] & c2[0]
    signal first_stage_xor: slv_array_t(1 downto 0)(3 downto 0);
    signal second_stage_xor: slv_array_t(1 downto 0)(3 downto 0);
    signal third_stage_xor: slv_array_t(1 downto 0)(5 downto 0);

    signal vld_shift_reg: std_logic_vector(2 downto 0);

    -- assigning DON'T TOUCH attribute
    attribute dont_touch: string;
    attribute dont_touch of behav: architecture is "yes";

    attribute dont_touch of sec_and_x, sec_and_y: signal is "yes";
    attribute dont_touch of first_stage_xor, second_stage_xor, third_stage_xor: signal is "yes";
begin
    s_axis_tready <= data_count_last;

    coeffs <= coeffs_r;
    coeffs_vld <= coeffs_vld_r;

    sec_and: entity work.sec_and
    generic map (
        W => 18
    )
    port map (
        clk => clk,

        x => sec_and_x,
        y => sec_and_y,

        r => sec_and_r,

        z => sec_and_z
    );

    sec_and_r(0) <= random;

    sec_and_shares_g: for i in 0 to 1 generate
        -- first stage carries
        sec_and_first_g: for j in 0 to 3 generate
            sec_and_x(i)(3 * j) <= s_axis_tdata(i)(3 * j + 12 * data_count) and s_axis_tvalid;
            sec_and_y(i)(3 * j) <= s_axis_tdata(i)(1 + 3 * j + 12 * data_count) and s_axis_tvalid;

            sec_and_x(i)(1 + 3 * j) <= s_axis_tdata(i)(3 * j + 12 * data_count) and s_axis_tvalid;
            sec_and_y(i)(1 + 3 * j) <= s_axis_tdata(i)(2 + 3 * j + 12 * data_count) and s_axis_tvalid;

            sec_and_x(i)(2 + 3 * j) <= s_axis_tdata(i)(1 + 3 * j + 12 * data_count) and s_axis_tvalid;
            sec_and_y(i)(2 + 3 * j) <= s_axis_tdata(i)(2 + 3 * j + 12 * data_count) and s_axis_tvalid;
        end generate;

        -- second stage carries
        sec_and_second_g: for j in 0 to 1 generate
            sec_and_x(i)(12 + 2 * j) <= first_stage_xor(i)(2 * j);

            sec_and_y(0)(12 + 2 * j) <= not first_stage_xor(0)(1 + 2 * j);
            sec_and_y(1)(12 + 2 * j) <= first_stage_xor(1)(1 + 2 * j);

            sec_and_x(i)(13 + 2 * j) <= sec_and_z(i)(6 * j) xor sec_and_z(i)(1 + 6 * j) xor sec_and_z(i)(2 + 6 * j);

            sec_and_y(0)(13 + 2 * j) <= not (sec_and_z(0)(3 + 6 * j) xor sec_and_z(0)(4 + 6 * j) xor sec_and_z(0)(5 + 6 * j));
            sec_and_y(1)(13 + 2 * j) <= sec_and_z(1)(3 + 6 * j) xor sec_and_z(1)(4 + 6 * j) xor sec_and_z(1)(5 + 6 * j);
        end generate;

        -- third stage
        sec_and_third_g: for j in 0 to 1 generate
            sec_and_x(i)(16 + j) <= second_stage_xor(i)(1 + 2 * j);
            sec_and_y(i)(16 + j) <= sec_and_z(i)(12 + 2 * j);
        end generate;
    end generate;

    xor_p: process(clk) is
    begin
        if rising_edge(clk) then
            if s_axis_tvalid = '1' then
                for i in 0 to 1 loop
                    for j in 0 to 3 loop
                        first_stage_xor(i)(j) <= s_axis_tdata(i)(3 * j + 12 * data_count) xor s_axis_tdata(i)(1 + 3 * j + 12 * data_count) xor s_axis_tdata(i)(2 + 3 * j + 12 * data_count);
                    end loop;
                end loop;
            end if;

            for j in 0 to 1 loop
                second_stage_xor(0)(2 * j) <= first_stage_xor(0)(2 * j) xor (not first_stage_xor(0)(1 + 2 * j));
                second_stage_xor(1)(2 * j) <= first_stage_xor(1)(2 * j) xor first_stage_xor(1)(1 + 2 * j);

                second_stage_xor(0)(1 + 2 * j) <= sec_and_z(0)(6 * j) xor sec_and_z(0)(1 + 6 * j) xor sec_and_z(0)(2 + 6 * j) xor (not (sec_and_z(0)(3 + 6 * j) xor sec_and_z(0)(4 + 6 * j) xor sec_and_z(0)(5 + 6 * j)));
                second_stage_xor(1)(1 + 2 * j) <= sec_and_z(1)(6 * j) xor sec_and_z(1)(1 + 6 * j) xor sec_and_z(1)(2 + 6 * j) xor sec_and_z(1)(3 + 6 * j) xor sec_and_z(1)(4 + 6 * j) xor sec_and_z(1)(5 + 6 * j);
            end loop;

            for i in 0 to 1 loop
                for j in 0 to 1 loop
                    third_stage_xor(i)(3 * j) <= second_stage_xor(i)(2 * j);
                    third_stage_xor(i)(1 + 3 * j) <= second_stage_xor(i)(1 + 2 * j) xor sec_and_z(i)(12 + 2 * j);

                    third_stage_xor(0)(2 + 3 * j) <= sec_and_z(0)(13 + 2 * j);
                    third_stage_xor(1)(2 + 3 * j) <= sec_and_z(1)(13 + 2 * j);
                end loop;
            end loop;
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
                if s_axis_tvalid = '1' then
                    if data_count_last = '1' then
                        data_count <= 0;
                    else
                        data_count <= data_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    coeffs_count_last <= '1' when coeffs_count = 3 else '0';

    -- count read coeffs words (4b)
    coeffs_count_p: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                coeffs_count <= 0;
            else
                if vld_shift_reg(0) = '1' then
                    if coeffs_count_last = '1' then
                        coeffs_count <= 0;
                    else
                        coeffs_count <= coeffs_count + 1;
                    end if;
                end if;
            end if;
        end if;
    end process;

    coeffs_p: process(clk) is
    begin
        if rising_edge(clk) then
            for i in 0 to 1 loop
                for j in 0 to 1 loop
                    coeffs_r(i)(3 * j + 6 * coeffs_count) <= third_stage_xor(i)(3 * j);
                    coeffs_r(i)(1 + 3 * j + 6 * coeffs_count) <= third_stage_xor(i)(1 + 3 * j);
                    coeffs_r(i)(2 + 3 * j + 6 * coeffs_count) <= sec_and_z(i)(16 + j) xor third_stage_xor(i)(2 + 3 * j);
                end loop;
            end loop;

            if rst = '1' then
                coeffs_vld_r <= '0';
            else
                coeffs_vld_r <= vld_shift_reg(0) and coeffs_count_last;
            end if;
        end if;
    end process;

    vld_p: process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                vld_shift_reg <= (others => '0');
            else
                vld_shift_reg <= s_axis_tvalid & vld_shift_reg(vld_shift_reg'left downto 1);
            end if;
        end if;
    end process;
end;
