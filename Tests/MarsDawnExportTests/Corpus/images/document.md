# Images IMGHEAD01

Paragraph before relative image REL01.

![relative](img/rel.png)

Paragraph before dot-relative image REL02.

![dot relative](./img/rel2.png)

Paragraph before absolute image ABS03.

![absolute]({{FIXTURE_DIR}}/img/abs.png)

Paragraph before dotdot-normalized image NORM04.

![normalized](nested/../img/rel.png)

Paragraph before out-of-scope parent image OOS05.

![outside](../outside.png)

Paragraph before nonexistent absolute path NOABS06.

![nonexistent absolute](/nonexistent-marsdawn/outside.png)

Paragraph before missing relative file MISS07.

![missing](missing.png)

Paragraph before blocked remote image REMOTE08.

![remote](https://example.com/remote.png)

A short closing paragraph to keep this fixture off the page-bottom edge (redtear1115/mars-dawn-kit#20), so the last marker below lands on real content rather than a trailing blank page.

Last paragraph marker IMGENDMARK99.
