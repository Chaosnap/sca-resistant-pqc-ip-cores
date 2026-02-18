-- Copyright (C) 2024 Patrik Dobias <xdobia13@vut.cz>
-- Released for the non-commercial use only. For licensing, please contact <malina@vut.cz>

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.params_pkg.all;
use work.reduce_pkg.all;

-- butterfly unit that is used during NTT/INTT and polynomial multiplication
-- all of these operations are implemented in one component, so it is possible to share resources
entity butterfly is
port (
    clk: in std_logic;
    rst: in std_logic;

    -- describing what operation is this component used in:
    -- - 000 => kyber NTT
    -- - 001 => kyber INTT
    -- - 010 => kyber polynomial multiplication (part 1)
    -- - 011 => kyber polynomial multiplication (part 2)
    -- - 100 => dilithium NTT
    -- - 101 => dilithium INTT
    -- - 110 => dilithium polynomial multiplication
    mode: in std_logic_vector(2 downto 0);

    a: in std_logic_vector(23 downto 0);
    b: in std_logic_vector(23 downto 0);

    zeta: in std_logic_vector(23 downto 0);

    c: out std_logic_vector(23 downto 0);
    d: out std_logic_vector(23 downto 0);

    -- sometimes it is needed to perform addition or subtraction with coefficients that are already in memory
    inplace_coeffs: in std_logic_vector(23 downto 0);
    -- determines type of operation
    -- 00 - no operation
    -- 01, 11 - addition
    -- 10 - subtration
    inplace_op: in std_logic_vector(1 downto 0);
    inplace_next: out std_logic;

    vld_in: in std_logic;
    vld_out: out std_logic
);
end;

architecture behav of butterfly is
    constant MUL_DELAY: natural := 4;

    type x3b_shift_reg_t is array(natural range <>) of std_logic_vector(2 downto 0);
    type x12b_shift_reg_t is array(natural range <>) of std_logic_vector(11 downto 0);
    type x24b_shift_reg_t is array(natural range <>) of std_logic_vector(23 downto 0);

    -- compute x * 2^-1 mod Q, make sure range stays <0; Q)
    function div_by_2(x: std_logic_vector(23 downto 0); mode: std_logic) return std_logic_vector is
        variable x_prep: std_logic_vector(23 downto 0);
        variable q, q_prep: std_logic_vector(23 downto 0);
        variable one: std_logic_vector(12 downto 0);
    begin
        x_prep(23 downto 12) := '0' & x(23 downto 13);
        x_prep(11 downto 0) := x(12 downto 1) when mode = '1' else '0' & x(11 downto 1);

        q := DILITHIUM_Q when mode = '1' else KYBER_Q & KYBER_Q;
        q_prep(23 downto 12) := '0' & q(23 downto 13);
        q_prep(11 downto 0) := q(12 downto 1) when mode = '1' else '0' & q(11 downto 1);

        q_prep(23 downto 12) := q_prep(23 downto 12) when ((mode and x(0)) or (not mode and x(12))) = '1' else (23 downto 12 => '0');
        q_prep(11 downto 0) := q_prep(11 downto 0) when x(0) = '1' else (11 downto 0 => '0');

        one := (0 => x(0), 12 downto 1 => '0') when mode = '1' else (0 => x(0), 11 downto 1 => '0', 12 => x(12));

        return std_logic_vector(unsigned(x_prep) + unsigned(q_prep) + unsigned(one));
    end;

    -- preprocessing results
    signal a_shift_reg, b_shift_reg: x24b_shift_reg_t(1 downto 0);
    -- zeta must be registered to match preprocessing delay
    signal zeta_shift_reg: x24b_shift_reg_t(1 downto 0);

    -- one coefficient is used during multiplication, second is used only in postprocessing, so it needs to be registered to match the delay
    signal skip_mul_shift_reg: x24b_shift_reg_t(MUL_DELAY + BARRETT_REDUCE_DELAY downto 0);

    -- multiplication signals
    signal mul0_x: std_logic_vector(23 downto 0);
    signal mul0_y: std_logic_vector(11 downto 0);
    signal mul1_x: x24b_shift_reg_t(1 downto 0);
    signal mul1_y: x12b_shift_reg_t(1 downto 0);
    signal mul0_z, mul1_z: std_logic_vector(35 downto 0);
    signal mul0_z_shifted, mul_z: std_logic_vector(47 downto 0);

    -- multiplication result after barrett reduction
    signal reduced, reduced_with_inplace: std_logic_vector(23 downto 0);

    signal inplace_coeffs_reg: std_logic_vector(23 downto 0);
    signal inplace_op_reg: std_logic_vector(1 downto 0);

    -- postprocessing results
    signal c_reg, d_reg: std_logic_vector(23 downto 0);

    -- mode register, so it is possible to change mode in every cycle
    signal mode_shift_reg: x3b_shift_reg_t(MUL_DELAY + BARRETT_REDUCE_DELAY + 2 downto 0);

    -- delay of this components depends on the multiplication and reduction delay + there are 3 more cyles for computations before and after multiplication + 1 for inplace addition/subtraction
    signal vld_shift_reg: std_logic_vector(MUL_DELAY + BARRETT_REDUCE_DELAY + 3 downto 0);
begin
    c <= c_reg;
    d <= d_reg;

    inplace_next <= vld_shift_reg(3) when inplace_op /= "00" else '0';

    vld_out <= vld_shift_reg(0);

    -- reduction of multiplication result
    reduce: entity work.barrett_reduce
    port map (
        clk => clk,
        rst => rst,

        mode => mode_shift_reg(mode_shift_reg'left - 4)(2),

        x => mul_z,
        z => reduced,

        vld_in => vld_shift_reg(vld_shift_reg'left - 5),
        vld_out => open -- valid is not used, as this component has constant delay
    );

    -- computations before multiplication
    proc_preprocess: process(clk) is
    begin
        if rising_edge(clk) then
            if vld_in = '1' then
                a_shift_reg(1) <= a;
                b_shift_reg(1) <= b;
                zeta_shift_reg(1) <= zeta;
            end if;

            case mode_shift_reg(mode_shift_reg'left)(1 downto 0) is
                when "01" =>
                    -- B + A
                    a_shift_reg(0) <= add_reduce(b_shift_reg(1), a_shift_reg(1), mode_shift_reg(mode_shift_reg'left)(2));
                    -- B - A
                    b_shift_reg(0) <= sub_reduce(b_shift_reg(1), a_shift_reg(1), mode_shift_reg(mode_shift_reg'left)(2));
                when "10" =>
                    -- B + A
                    a_shift_reg(0) <= add_reduce(b_shift_reg(1), a_shift_reg(1), mode_shift_reg(mode_shift_reg'left)(2));
                    b_shift_reg(0) <= b_shift_reg(1);
                when others =>
                    a_shift_reg(0) <= a_shift_reg(1);
                    b_shift_reg(0) <= b_shift_reg(1);
            end case;

            zeta_shift_reg(0) <= zeta_shift_reg(1);
        end if;
    end process;

    -- multiply values stored in `b_shift_reg` and `zeta_shift_reg`, either (a * b) for dilithium or (a(23 downto 12) * b(23 downto 12)) & (a(11 downto 0) * b(11 downto 0))
    -- uses multiplication algorithm as proposed in https://ieeexplore.ieee.org/stamp/stamp.jsp?tp=&arnumber=9946370
    proc_mul: process(clk) is
    begin
        if rising_edge(clk) then
            -- delay `a_shift_reg` and `mode`, so it is available when multiplication is finished
            skip_mul_shift_reg <= a_shift_reg(0) & skip_mul_shift_reg(skip_mul_shift_reg'left downto 1);
            mode_shift_reg <= mode & mode_shift_reg(mode_shift_reg'left downto 1);

            -- select correct input coefficients
            if mode_shift_reg(mode_shift_reg'left - 1)(2) = '0' then
                mul0_x <= (11 downto 0 => '0') & b_shift_reg(0)(23 downto 12);
                mul1_x(1) <= (11 downto 0 => '0') & b_shift_reg(0)(11 downto 0);
                mul1_x(0) <= mul1_x(1);
            else
                mul0_x <= '0' & b_shift_reg(0)(22 downto 0);
                mul1_x(1) <= '0' & b_shift_reg(0)(22 downto 0);
                mul1_x(0) <= mul1_x(1);
            end if;

            mul0_y <= zeta_shift_reg(0)(23 downto 12);
            mul1_y <= zeta_shift_reg(0)(11 downto 0) & mul1_y(mul1_y'left downto 1);

            -- multiply upper bits
            mul0_z <= std_logic_vector(unsigned(mul0_x) * unsigned(mul0_y));
            -- multiply lower bits
            mul1_z <= std_logic_vector(unsigned(mul1_x(0)) * unsigned(mul1_y(0)));

            -- shift upper bits correctly before addition
            if mode_shift_reg(mode_shift_reg'left - 3)(2) = '0' then
                mul0_z_shifted <= mul0_z(23 downto 0) & (23 downto 0 => '0');
            else
                mul0_z_shifted <= mul0_z(35 downto 0) & (11 downto 0 => '0');
            end if;

            -- add upper and lower bits
            mul_z <= std_logic_vector(unsigned(mul1_z) + unsigned(mul0_z_shifted));
        end if;
    end process;

    -- computes addition or subtraction with coefficients currently in the corresponding memory
    -- TODO: this should be done after postprocess, now it works correctly only during NTT and multiplication, but would break during INTT (not needed right now)
    -- would have to be duplicated, maybe it is just better here
    proc_inplace: process(clk) is
    begin
        if rising_edge(clk) then
            if vld_shift_reg(3) = '1' then
                inplace_coeffs_reg <= inplace_coeffs;
                inplace_op_reg <= inplace_op;
            end if;

            case inplace_op_reg is
                when "01" | "11" => reduced_with_inplace <= add_reduce(inplace_coeffs_reg, reduced, mode_shift_reg(1)(2));
                when "10" => reduced_with_inplace <= sub_reduce(inplace_coeffs_reg, reduced, mode_shift_reg(1)(2));
                when others => reduced_with_inplace <= reduced;
            end case;
        end if;
    end process;

    -- computations after multiplication
    proc_postprocess: process(clk) is
    begin
        if rising_edge(clk) then
            case mode_shift_reg(0)(1 downto 0) is
                when "00" =>
                    -- C = A + B * zeta
                    c_reg <= add_reduce(skip_mul_shift_reg(0), reduced_with_inplace, mode_shift_reg(0)(2));
                    -- D = A - B * zeta
                    d_reg <= sub_reduce(skip_mul_shift_reg(0), reduced_with_inplace, mode_shift_reg(0)(2));
                -- during INTT divide also results by 2, so it does not have to be divided in separate loop by 256
                when "01" =>
                    -- C = (B + A) * 2^-1
                    c_reg <= div_by_2(skip_mul_shift_reg(0), mode_shift_reg(0)(2));
                    -- D = (B - A) * zeta * 2^-1
                    d_reg <= div_by_2(reduced_with_inplace, mode_shift_reg(0)(2));
                when "10" =>
                    -- C = A + B
                    c_reg <= skip_mul_shift_reg(0);
                    -- D = B * ZETA
                    d_reg <= reduced_with_inplace;
                when "11" =>
                    -- C = A - this is not needed
                    c_reg <= skip_mul_shift_reg(0);
                    -- D = B * ZETA - A
                    d_reg <= sub_reduce(reduced_with_inplace, skip_mul_shift_reg(0), mode_shift_reg(0)(2));
                when others =>
            end case;
        end if;
    end process;

    process(clk) is
    begin
        if rising_edge(clk) then
            if rst = '1' then
                vld_shift_reg <= (others => '0');
            else
                vld_shift_reg <= vld_in & vld_shift_reg(vld_shift_reg'left downto 1);
            end if;
        end if;
    end process;
end;
