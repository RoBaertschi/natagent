package time2

import "core:fmt"
import "core:time"

main :: proc() {
	now := time.time_add(time.now(), time.Minute * 4)
	fmt.print(now._nsec)
}
