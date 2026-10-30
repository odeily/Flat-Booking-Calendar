import 'package:flutter/material.dart';

/// Cabecera compacta de columna semanal (`L`, `M`, `X`, `J`, `V`, `S`, `D`) para cuadrículas mensuales.
class HeaderDia extends StatelessWidget {
  final String texto;

  const HeaderDia(this.texto, {super.key});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      child: Text(
        texto,
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          fontSize: 13,
          color: Color(0xFF64748B),
        ),
      ),
    );
  }
}
