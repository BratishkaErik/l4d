package ya.neznau.l4d

import org.springframework.boot.autoconfigure.SpringBootApplication
import org.springframework.boot.runApplication

@SpringBootApplication
class L4dApplication

fun main(args: Array<String>) {
	runApplication<L4dApplication>(*args)
}
