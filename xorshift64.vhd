---------------------------------------------------------------------------------
-- file name: xorshift64.vhd
-- DESCRIPTION:
--		64-bit PRNG (George Marsaglia, 2003)
--		x ^= x << 13;
--		x ^= x >> 7;
--		x ^= x << 17;
----------------------------------------------------------------------------------
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;


entity xorshift64 is
	port (
		clk			: in  std_logic;
		rst_n		: in  std_logic;
		enable		: in std_logic;
		load_seed	: in  std_logic;
		seed_in		: in  std_logic_vector(63 downto 0);

		rand_out	: out std_logic_vector(63 downto 0)
	);
end entity;

architecture rtl of xorshift64 is
	signal reg : std_logic_vector(63 downto 0);

begin

	rand_out <= reg;

	process(clk, rst_n)

		variable temp : std_logic_vector(63 downto 0);
	begin
		if rst_n = '0' then
			reg <= x"0000000000000001";
		elsif rising_edge(clk) then

			if load_seed = '1' then
				-- protection from initializing with 0
				if seed_in = x"0000000000000000" then
					reg <= x"0000000000000001";
				else
					reg <= seed_in;
				end if;
			elsif enable = '1' then
				-- George Marsaglia algorithm (shifts: L13, R7, L17)
				temp	:= reg xor ( reg(50 downto 0) & "0000000000000" );-- x ^= x << 13
				temp	:= temp xor ( "0000000" & temp(63 downto 7) );--x ^= x >> 7
				reg		<= temp xor ( temp(46 downto 0) & "00000000000000000" );--x ^= x << 17

				end if;

		end if;
	end process;

end rtl;
